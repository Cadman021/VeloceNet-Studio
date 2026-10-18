import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/ffi/native_bindings.dart';
import '../../core/validation/host_validator.dart';
import '../../models/traceroute_hop.dart';
import '../../models/traceroute_progress.dart';

class TracerouteController extends ChangeNotifier {
  final NativeBindings _bindings = NativeBindings();

  TracerouteProgress _progress = TracerouteProgress.initial('');
  Timer? _pollTimer;
  int _activeSessionId = 0;
  Process? _fallbackProcess;
  StreamSubscription<String>? _fallbackSub;
  bool _isUsingNative = false;
  // One-shot guard: if the native worker dies because the OS refused ICMP
  // (no ping-socket permission on Linux/macOS, IcmpCreateFile failure on
  // Windows), fall back to the system prober once instead of looping.
  bool _nativeFallbackTried = false;
  // Generation counter: async callbacks from a previous run (stdout lines,
  // exit codes, DNS lookups) are ignored once a new run starts or stop()
  // is called. Without this, a killed process's buffered output would
  // overwrite the new trace's progress (stale-write race).
  int _runId = 0;
  // Reverse DNS runs here, not in the native worker: a PTR lookup can block
  // for seconds per hop and would stretch the hop timeout. Results are
  // cached per IP and overlaid on every poll snapshot (the engine sends
  // hostname = null).
  final Map<String, String> _reverseNames = {};
  final Set<String> _reverseTried = {};
  bool _reverseBusy = false;

  TracerouteProgress get progress => _progress;
  bool get isRunning => _progress.isRunning;
  bool get isNativeAvailable => _bindings.isTracerouteReady;
  bool get isUsingNative => _isUsingNative;
  List<TracerouteHop> get hops => _progress.hops;

  int get totalHops => _progress.hops.length;
  bool get reachedDestination =>
      _progress.hops.isNotEmpty &&
      _progress.hops.any((h) => h.reachedDestination);

  double get averageRtt {
    final validHops =
        _progress.hops.where((h) => !h.isTimeout && h.rttMs > 0).toList();
    if (validHops.isEmpty) return 0.0;
    final sum = validHops.fold<double>(0.0, (acc, h) => acc + h.rttMs);
    return sum / validHops.length;
  }

  int get timeoutCount => _progress.hops.where((h) => h.isTimeout).length;

  double get minRtt {
    final validHops =
        _progress.hops.where((h) => !h.isTimeout && h.rttMs > 0).toList();
    if (validHops.isEmpty) return 0.0;
    return validHops.map((h) => h.rttMs).reduce((a, b) => a < b ? a : b);
  }

  double get maxRtt {
    final validHops =
        _progress.hops.where((h) => !h.isTimeout && h.rttMs > 0).toList();
    if (validHops.isEmpty) return 0.0;
    return validHops.map((h) => h.rttMs).reduce((a, b) => a > b ? a : b);
  }

  void start(String rawHost, {int maxHops = 30, int timeoutMs = 1500}) {
    final host = normalizeTraceHost(rawHost);
    if (host == null) {
      _progress = TracerouteProgress.initial(rawHost.trim()).copyWith(
        isRunning: false,
        isCompleted: false,
        error: 'Invalid host. Use an IPv4/IPv6 address or hostname.',
      );
      notifyListeners();
      return;
    }
    // Clamp before crossing FFI (native maxHops is a u8; unclamped Dart
    // ints would truncate) and before building system-prober arguments.
    maxHops = maxHops.clamp(1, 64);
    timeoutMs = timeoutMs.clamp(100, 10000);

    stop();
    _nativeFallbackTried = false;

    _progress = TracerouteProgress(
      sessionId: 0,
      targetHost: host,
      targetIp: '',
      maxHops: maxHops,
      currentHop: 0,
      isRunning: true,
      isCompleted: false,
      error: null,
      hops: const [],
    );
    notifyListeners();

    // Native ICMP tracing on every desktop platform: Windows via
    // Iphlpapi, Linux/macOS via unprivileged ping sockets (SOCK_DGRAM).
    // Where the OS refuses ICMP, the native worker reports an error and
    // the poll loop flips to the system `traceroute` binary.
    if (_bindings.isTracerouteReady) {
      _startNativeTraceroute(host, maxHops, timeoutMs);
    } else {
      _startFallbackTraceroute(host, maxHops, timeoutMs);
    }
  }

  void _startNativeTraceroute(String host, int maxHops, int timeoutMs) {
    _isUsingNative = true;
    _activeSessionId = _bindings.startTraceroute(host, maxHops, timeoutMs);

    if (_activeSessionId == 0) {
      // Native start failed, fallback to system prober
      _startFallbackTraceroute(host, maxHops, timeoutMs);
      return;
    }

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      if (_activeSessionId == 0) {
        timer.cancel();
        return;
      }
      final jsonStr = _bindings.pollTraceroute(_activeSessionId);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        try {
          final Map<String, dynamic> map = jsonDecode(jsonStr);
          final next = _withReverseNames(TracerouteProgress.fromJson(map));
          _scheduleReverseLookups(next.hops);

          // Only rebuild UI when something actually changed. Rebuilding
          // on every poll causes layout churn on Windows desktop.
          final bool hopsChanged = next.hops.length != _progress.hops.length;
          final bool stateChanged = next.isCompleted != _progress.isCompleted ||
              next.isRunning != _progress.isRunning ||
              next.currentHop != _progress.currentHop ||
              next.targetIp != _progress.targetIp;

          _progress = next;
          if (hopsChanged || stateChanged) {
            notifyListeners();
          }

          if (_progress.isCompleted) {
            timer.cancel();
            _bindings.freeTraceroute(_activeSessionId);
            _activeSessionId = 0;
            // Runtime ICMP refusal (ping_group_range / no CAP_NET_RAW,
            // IcmpCreateFile denied): the run dies with an error and zero
            // hops — retry once through the system traceroute instead of
            // leaving an error-only screen.
            if (!_nativeFallbackTried &&
                _progress.error != null &&
                _progress.hops.isEmpty) {
              _nativeFallbackTried = true;
              _progress = TracerouteProgress.initial(host).copyWith(
                maxHops: maxHops,
                isRunning: true,
              );
              notifyListeners();
              unawaited(_startFallbackTraceroute(host, maxHops, timeoutMs));
            }
          }
        } catch (e) {
          debugPrint('Traceroute poll parse error: $e');
        }
      }
    });
  }

  Future<void> _startFallbackTraceroute(
      String host, int maxHops, int timeoutMs) async {
    _isUsingNative = false;
    final int runId = ++_runId;

    // Resolve target IP first (prefer IPv4: the system probers below and
    // the destination check both assume v4 unless the target is IPv6).
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(Duration(milliseconds: timeoutMs));
      if (runId != _runId) return; // superseded while resolving
      if (addrs.isNotEmpty) {
        final v4 = addrs.where((a) => a.type == InternetAddressType.IPv4);
        final target = (host.contains(':')
            ? addrs.first
            : v4.isNotEmpty
                ? v4.first
                : addrs.first);
        _progress = _progress.copyWith(targetIp: target.address);
        notifyListeners();
      }
    } catch (_) {
      if (runId != _runId) return;
    }

    final List<TracerouteHop> collectedHops = [];
    final executable = Platform.isWindows ? 'tracert' : 'traceroute';
    final arguments = Platform.isWindows
        ? ['-d', '-h', '$maxHops', '-w', '$timeoutMs', host]
        : ['-n', '-m', '$maxHops', '-w', '${(timeoutMs / 1000).ceil()}', host];

    Process? proc;
    try {
      proc = await Process.start(executable, arguments);
    } catch (e) {
      if (runId != _runId) return;
      _progress = _progress.copyWith(
        isRunning: false,
        isCompleted: true,
        error: 'System traceroute failed: $e',
      );
      notifyListeners();
      return;
    }
    if (runId != _runId) {
      // A newer run (or stop) already took over; kill this orphan.
      proc.kill();
      return;
    }
    _fallbackProcess = proc;

    // NOTE: `tracert`/`traceroute` print in the console OEM codepage
    // (e.g. cp866/cp936 on Russian/Chinese Windows), NOT UTF-8. A strict
    // decoder throws FormatException on the first non-UTF8 byte and — with
    // no onError handler — the error escapes into the zone and kills the
    // app. Lenient decoding keeps the trace alive (mojibake in the worst
    // case, which the IP/RTT regexes skip over).
    _fallbackSub = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (runId != _runId) return; // stale output from a killed run
        final parsedHop = _parseTracertLine(line);
        if (parsedHop != null) {
          collectedHops.removeWhere((h) => h.hopNum == parsedHop.hopNum);
          collectedHops.add(parsedHop);
          _progress = _progress.copyWith(
            currentHop: parsedHop.hopNum,
            hops: List.from(collectedHops),
          );
          notifyListeners();
          _scheduleReverseLookups(collectedHops);
        }
      },
      onError: (_) {
        // Decoding/pipe hiccup mid-trace: keep previously collected hops.
        debugPrint('Traceroute stdout error; keeping partial hops.');
      },
      cancelOnError: false,
    );

    proc.exitCode.then((code) {
      if (runId != _runId) return; // stopped or superseded; leave state alone
      _progress = _progress.copyWith(
        isRunning: false,
        isCompleted: true,
      );
      notifyListeners();
    });
  }

  TracerouteHop? _parseTracertLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;

    // Windows tracert line, e.g.:
    // 1    <1 ms    <1 ms    <1 ms  192.168.1.1
    // 2      *        *        *     Request timed out.
    final winHopRegex = RegExp(r'^(\d+)\s+(.+)$');
    final match = winHopRegex.firstMatch(trimmed);
    if (match == null) return null;

    final hopNum = int.tryParse(match.group(1)!) ?? 0;
    if (hopNum == 0) return null;

    final rest = match.group(2)!;

    if (rest.contains('Request timed out') || rest.contains('* * *')) {
      return TracerouteHop(
        hopNum: hopNum,
        ip: '*',
        rttMs: -1.0,
        isTimeout: true,
        reachedDestination: false,
        status: 'Request Timed Out',
      );
    }

    // Look for IP address: IPv4 first, then IPv6 literal.
    // (`-d`/`-n` keep output numeric, so tokens are clean addresses.)
    String ipStr = '*';
    final ipv4Match =
        RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})').firstMatch(rest);
    if (ipv4Match != null) {
      ipStr = ipv4Match.group(1)!;
    } else {
      final ipv6Match = RegExp(
        r'((?:[0-9A-Fa-f]{1,4}:){2,}[0-9A-Fa-f:.]{0,45})(?=\s|$)',
      ).firstMatch(rest);
      if (ipv6Match != null) ipStr = ipv6Match.group(1)!;
    }

    // Average all RTT samples on the line (Windows prints 3, Linux prints
    // 3 decimals like "0.123 ms"). `<1 ms` counts as 0.5; `*` is skipped.
    // The old code used only the first sample and truncated decimals.
    final rttRegex = RegExp(r'(<1\s*ms|\d+(?:\.\d+)?\s*ms)');
    double rttSum = 0;
    int rttCount = 0;
    for (final m in rttRegex.allMatches(rest)) {
      final raw = m.group(1)!;
      if (raw.startsWith('<')) {
        rttSum += 0.5;
        rttCount++;
      } else {
        final num = RegExp(r'\d+(?:\.\d+)?').firstMatch(raw);
        if (num != null) {
          final v = double.tryParse(num.group(0)!);
          if (v != null) {
            rttSum += v;
            rttCount++;
          }
        }
      }
    }
    final double rtt = rttCount > 0 ? rttSum / rttCount : 1.0;

    final isDest = _progress.targetIp.isNotEmpty && ipStr == _progress.targetIp;

    return TracerouteHop(
      hopNum: hopNum,
      ip: ipStr,
      rttMs: rtt,
      isTimeout: ipStr == '*',
      reachedDestination: isDest,
      status: isDest ? 'Destination Reached' : 'Time Exceeded in Transit',
    );
  }

  /// Overlays cached PTR names onto freshly polled hops (native progress has
  /// `hostname: null`). Called on every poll so names survive snapshots.
  TracerouteProgress _withReverseNames(TracerouteProgress progress) {
    if (_reverseNames.isEmpty) return progress;
    var changed = false;
    final hops = progress.hops.map((hop) {
      if (hop.hostname != null) return hop;
      final name = _reverseNames[hop.ip];
      if (name == null) return hop;
      changed = true;
      return hop.copyWith(hostname: name);
    }).toList(growable: false);
    return changed ? progress.copyWith(hops: hops) : progress;
  }

  void _scheduleReverseLookups(List<TracerouteHop> hops) {
    final pending = <String>{};
    for (final hop in hops) {
      if (hop.isTimeout || hop.ip == '*' || hop.hostname != null) continue;
      if (_reverseTried.contains(hop.ip)) continue;
      pending.add(hop.ip);
    }
    if (pending.isEmpty || _reverseBusy) return;
    _reverseBusy = true;
    unawaited(_runReverseLookups(pending.toList()));
  }

  Future<void> _runReverseLookups(List<String> ips) async {
    var next = 0;
    Future<void> worker() async {
      while (next < ips.length) {
        final ip = ips[next++];
        if (!_reverseTried.add(ip)) continue;
        try {
          final name = await InternetAddress(ip)
              .reverse()
              .timeout(const Duration(seconds: 2));
          if (name.host.isNotEmpty) {
            _reverseNames[ip] = name.host;
          }
        } catch (_) {
          // No PTR record or resolver timeout: the IP remains the label.
        }
        if (_progress.hops.any((h) => h.ip == ip && h.hostname == null)) {
          _progress = _withReverseNames(_progress);
          notifyListeners();
        }
      }
    }

    try {
      // Bounded concurrency: PTR lookups are fast when they exist, but a
      // missing record can burn the full timeout; six in flight keeps names
      // appearing without hammering the platform resolver.
      final workers = ips.length < 6 ? ips.length : 6;
      await Future.wait(List.generate(workers, (_) => worker()));
    } finally {
      _reverseBusy = false;
      // Hops appended while the lookups ran were skipped; queue them now.
      _scheduleReverseLookups(_progress.hops);
    }
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;

    // Invalidate any in-flight fallback callbacks (stdout/exitCode/DNS).
    _runId++;
    _fallbackSub?.cancel();
    _fallbackSub = null;

    final int sessionToFree = _activeSessionId;
    _activeSessionId = 0;
    if (sessionToFree != 0) {
      try {
        _bindings.stopTraceroute(sessionToFree);
      } catch (_) {}
      try {
        _bindings.freeTraceroute(sessionToFree);
      } catch (_) {}
    }

    if (_fallbackProcess != null) {
      try {
        _fallbackProcess!.kill();
      } catch (_) {}
      _fallbackProcess = null;
    }

    if (_progress.isRunning) {
      _progress = _progress.copyWith(
        isRunning: false,
        isCompleted: true,
      );
      notifyListeners();
    }
  }

  void reset() {
    stop();
    _progress = TracerouteProgress.initial('');
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/ffi/native_bindings.dart';
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
  // Generation counter: async callbacks from a previous run (stdout lines,
  // exit codes, DNS lookups) are ignored once a new run starts or stop()
  // is called. Without this, a killed process's buffered output would
  // overwrite the new trace's progress (stale-write race).
  int _runId = 0;

  TracerouteProgress get progress => _progress;
  bool get isRunning => _progress.isRunning;
  bool get isNativeAvailable => _bindings.isTracerouteReady;
  bool get isUsingNative => _isUsingNative;
  List<TracerouteHop> get hops => _progress.hops;

  int get totalHops => _progress.hops.length;
  bool get reachedDestination =>
      _progress.hops.isNotEmpty && _progress.hops.any((h) => h.reachedDestination);

  double get averageRtt {
    final validHops = _progress.hops.where((h) => !h.isTimeout && h.rttMs > 0).toList();
    if (validHops.isEmpty) return 0.0;
    final sum = validHops.fold<double>(0.0, (acc, h) => acc + h.rttMs);
    return sum / validHops.length;
  }

  int get timeoutCount => _progress.hops.where((h) => h.isTimeout).length;

  double get minRtt {
    final validHops = _progress.hops.where((h) => !h.isTimeout && h.rttMs > 0).toList();
    if (validHops.isEmpty) return 0.0;
    return validHops.map((h) => h.rttMs).reduce((a, b) => a < b ? a : b);
  }

  double get maxRtt {
    final validHops = _progress.hops.where((h) => !h.isTimeout && h.rttMs > 0).toList();
    if (validHops.isEmpty) return 0.0;
    return validHops.map((h) => h.rttMs).reduce((a, b) => a > b ? a : b);
  }

  /// Validates a user-supplied trace target: IPv4, IPv6 (with or without
  /// brackets) or a DNS hostname. Returns the normalized host, or null.
  static String? normalizeTraceHost(String raw) {
    var host = raw.trim().replaceAll(RegExp(r'^https?://'), '').split('/')[0].trim();
    if (host.startsWith('[') && host.endsWith(']') && host.length > 2) {
      host = host.substring(1, host.length - 1);
    }
    if (host.isEmpty || host.length > 253) return null;
    // IPv4 (octet-checked, not just dotted digits).
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
      final ok = host.split('.').every((o) {
        final n = int.tryParse(o);
        return n != null && n >= 0 && n <= 255;
      });
      return ok ? host : null;
    }
    // IPv6 literal.
    if (host.contains(':')) {
      final addr = InternetAddress.tryParse(host);
      return (addr != null && addr.type == InternetAddressType.IPv6) ? host : null;
    }
    // Hostname (labels up to 63 chars, no leading/trailing hyphens).
    const label = r'[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?';
    if (RegExp('^$label(?:\\.$label)*\$').hasMatch(host)) return host;
    return null;
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
          final next = TracerouteProgress.fromJson(map);

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
          }
        } catch (e) {
          debugPrint('Traceroute poll parse error: $e');
        }
      }
    });
  }

  Future<void> _startFallbackTraceroute(String host, int maxHops, int timeoutMs) async {
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
        final target = (host.contains(':') ? addrs.first : v4.isNotEmpty ? v4.first : addrs.first);
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

    _fallbackSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
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
      }
    });

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
    final ipv4Match = RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})').firstMatch(rest);
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

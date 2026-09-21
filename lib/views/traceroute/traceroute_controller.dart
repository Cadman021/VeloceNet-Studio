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
  bool _isUsingNative = false;

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

  void start(String rawHost, {int maxHops = 30, int timeoutMs = 1500}) {
    final host = rawHost.trim().replaceAll(RegExp(r'^https?://'), '').split('/')[0];
    if (host.isEmpty) return;

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
          print('Traceroute poll parse error: $e');
        }
      }
    });
  }

  Future<void> _startFallbackTraceroute(String host, int maxHops, int timeoutMs) async {
    _isUsingNative = false;

    // Resolve target IP first
    try {
      final addrs = await InternetAddress.lookup(host);
      if (addrs.isNotEmpty) {
        _progress = _progress.copyWith(targetIp: addrs.first.address);
        notifyListeners();
      }
    } catch (_) {}

    final List<TracerouteHop> collectedHops = [];
    final executable = Platform.isWindows ? 'tracert' : 'traceroute';
    final arguments = Platform.isWindows
        ? ['-d', '-h', '$maxHops', '-w', '$timeoutMs', host]
        : ['-n', '-m', '$maxHops', '-w', '${(timeoutMs / 1000).ceil()}', host];

    try {
      _fallbackProcess = await Process.start(executable, arguments);

      _fallbackProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
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

      _fallbackProcess!.exitCode.then((code) {
        _progress = _progress.copyWith(
          isRunning: false,
          isCompleted: true,
        );
        notifyListeners();
      });
    } catch (e) {
      _progress = _progress.copyWith(
        isRunning: false,
        isCompleted: true,
        error: 'System traceroute failed: $e',
      );
      notifyListeners();
    }
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

    // Look for IP address
    final ipRegex = RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})');
    final ipMatch = ipRegex.firstMatch(rest);
    final ipStr = ipMatch != null ? ipMatch.group(1)! : '*';

    // Extract RTT
    final rttRegex = RegExp(r'(\d+)\s*ms|<1\s*ms');
    final rttMatches = rttRegex.allMatches(rest).toList();
    double rtt = 1.0;
    if (rttMatches.isNotEmpty) {
      final raw = rttMatches.first.group(0)!;
      if (raw.contains('<1')) {
        rtt = 0.5;
      } else {
        final numMatch = RegExp(r'\d+').firstMatch(raw);
        if (numMatch != null) {
          rtt = double.tryParse(numMatch.group(0)!) ?? 1.0;
        }
      }
    }

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
      _fallbackProcess!.kill();
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

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../core/ffi/native_bindings.dart';
import '../../models/bandwidth_snapshot.dart';

/// Polls the Rust bandwidth monitor once per second and keeps a rolling
/// history window. The window length is user-configurable in minutes
/// (default 1 minute = 60 samples at 1s polling).
///
/// Stability rules (learned from the traceroute phase on Windows desktop):
/// - Poll at 1s, notify listeners ONLY when a new snapshot arrived.
/// - No nested scrollables, no endless animation tickers in the UI.
class BandwidthController extends ChangeNotifier {
  final NativeBindings _bindings = NativeBindings();

  BandwidthSnapshot _latest = BandwidthSnapshot.empty();
  final List<BandwidthSnapshot> _history = [];
  Timer? _pollTimer;
  bool _running = false;
  int _lastTimestampMs = 0;

  /// Rolling window in minutes, editable from the UI. Default 1.
  int windowMinutes = 1;

  BandwidthSnapshot get latest => _latest;
  List<BandwidthSnapshot> get history => List.unmodifiable(_history);
  bool get isRunning => _running;
  bool get isNativeAvailable => _bindings.isBandwidthReady;

  int get maxSamples => (windowMinutes.clamp(1, 30)) * 60;

  void setWindowMinutes(int minutes) {
    windowMinutes = minutes.clamp(1, 30);
    _trimHistory();
    notifyListeners();
  }

  void start() {
    if (_running) return;
    _running = true;

    if (_bindings.isBandwidthReady) {
      _bindings.startBandwidth(1000);
    }

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    notifyListeners();
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_bindings.isBandwidthReady) {
      try {
        _bindings.stopBandwidth();
      } catch (_) {}
    }
    notifyListeners();
  }

  void clearHistory() {
    _history.clear();
    _lastTimestampMs = 0;
    notifyListeners();
  }

  void _poll() {
    if (!_running) return;
    if (!_bindings.isBandwidthReady) return;

    final jsonStr = _bindings.pollBandwidth();
    if (jsonStr == null || jsonStr.isEmpty) return;

    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final snap = BandwidthSnapshot.fromJson(map);

      // Skip duplicates (same timestamp = no new sample yet).
      if (snap.timestampMs != 0 && snap.timestampMs == _lastTimestampMs) return;
      _lastTimestampMs = snap.timestampMs;

      _latest = snap;
      _history.add(snap);
      _trimHistory();
      notifyListeners();
    } catch (_) {
      // Ignore malformed polls; next second will retry.
    }
  }

  void _trimHistory() {
    while (_history.length > maxSamples) {
      _history.removeAt(0);
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

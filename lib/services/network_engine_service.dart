import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../core/ffi/native_bindings.dart';
import '../models/ping_metric.dart';
import '../models/ping_target.dart';

class NetworkEngineService {
  final NativeBindings _bindings = NativeBindings();
  Pointer<Void>? _nativeEngine;
  bool _isRunning = false;
  Timer? _pollTimer;
  Timer? _fallbackTimer;

  final StreamController<List<PingMetric>> _metricsController =
      StreamController<List<PingMetric>>.broadcast();

  final List<PingTarget> _targets = [];
  final Map<int, PingMetric> _latestMetrics = {};

  bool get isNativeAvailable => _bindings.isReady;
  bool get isRunning => _isRunning;
  Stream<List<PingMetric>> get metricsStream => _metricsController.stream;

  void initialize(List<PingTarget> initialTargets) {
    // Free any previous native engine to avoid leaking the Tokio runtime.
    if (_nativeEngine != null) {
      try {
        _bindings.stopEngine(_nativeEngine!);
      } catch (_) {}
      try {
        _bindings.freeEngine(_nativeEngine!);
      } catch (_) {}
      _nativeEngine = null;
    }
    _pollTimer?.cancel();
    _fallbackTimer?.cancel();
    _isRunning = false;
    _targets.clear();
    _targets.addAll(initialTargets);

    for (final t in _targets) {
      _latestMetrics[t.id] = PingMetric.initial(
        t.id,
        t.name,
        t.host,
        t.port,
        t.protocol.label,
      );
    }

    if (isNativeAvailable) {
      _nativeEngine = _bindings.createEngine();
      if (_nativeEngine != null) {
        for (final t in _targets) {
          if (t.isEnabled) {
            _bindings.addTarget(
              _nativeEngine!,
              t.id,
              t.name,
              t.host,
              t.port,
              t.protocol.id,
              t.intervalMs,
              t.timeoutMs,
            );
          }
        }
      }
    }
  }

  void start() {
    if (_isRunning) return;

    if (isNativeAvailable && _nativeEngine != null) {
      final ok = _bindings.startEngine(_nativeEngine!);
      if (!ok) {
        // Native start failed -> fall back to Dart so UI never deadlocks.
        _startDartFallbackProber();
        _isRunning = true;
        return;
      }
      _isRunning = true;
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _pollNativeMetrics();
      });
    } else {
      _isRunning = true;
      _startDartFallbackProber();
    }
  }

  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _pollTimer?.cancel();
    _fallbackTimer?.cancel();

    if (isNativeAvailable && _nativeEngine != null) {
      _bindings.stopEngine(_nativeEngine!);
    }
  }

  void addTarget(PingTarget target) {
    _targets.removeWhere((t) => t.id == target.id);
    _targets.add(target);
    _latestMetrics[target.id] = PingMetric.initial(
      target.id,
      target.name,
      target.host,
      target.port,
      target.protocol.label,
    );

    if (isNativeAvailable && _nativeEngine != null && target.isEnabled) {
      _bindings.addTarget(
        _nativeEngine!,
        target.id,
        target.name,
        target.host,
        target.port,
        target.protocol.id,
        target.intervalMs,
        target.timeoutMs,
      );
    }
  }

  void removeTarget(int targetId) {
    _targets.removeWhere((t) => t.id == targetId);
    _latestMetrics.remove(targetId);

    if (isNativeAvailable && _nativeEngine != null) {
      _bindings.removeTarget(_nativeEngine!, targetId);
    }
  }

  void _pollNativeMetrics() {
    if (_nativeEngine == null) return;
    final jsonStr = _bindings.getMetricsJson(_nativeEngine!);
    if (jsonStr == null || jsonStr.isEmpty) return;

    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      final metrics = list.map((e) => PingMetric.fromJson(e as Map<String, dynamic>)).toList();

      for (final m in metrics) {
        _latestMetrics[m.id] = m;
      }
      _metricsController.add(_latestMetrics.values.toList());
    } catch (e) {
      debugPrint('Error decoding metrics: $e');
    }
  }

  void _startDartFallbackProber() {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer.periodic(const Duration(milliseconds: 800), (_) async {
      if (!_isRunning) return;

      final futures = _targets.where((t) => t.isEnabled).map((target) async {
        final stopwatch = Stopwatch()..start();
        bool success = false;
        double rtt = -1.0;

        try {
          final socket = await Socket.connect(
            target.host,
            target.port > 0 ? target.port : 80,
            timeout: Duration(milliseconds: target.timeoutMs),
          );
          stopwatch.stop();
          rtt = stopwatch.elapsedMicroseconds / 1000.0;
          socket.destroy();
          success = true;
        } catch (_) {
          stopwatch.stop();
          success = false;
          rtt = -1.0;
        }

        _updateFallbackMetric(target, success, rtt);
      });

      await Future.wait(futures);
      _metricsController.add(_latestMetrics.values.toList());
    });
  }

  void _updateFallbackMetric(PingTarget target, bool success, double rtt) {
    final prev = _latestMetrics[target.id] ??
        PingMetric.initial(target.id, target.name, target.host, target.port, target.protocol.label);

    final newSent = prev.sentCount + 1;
    final newRecv = prev.receivedCount + (success ? 1 : 0);
    final newLost = prev.lostCount + (success ? 0 : 1);
    final lossRate = (newLost / newSent) * 100.0;

    final history = List<double>.from(prev.history);
    if (history.length >= 40) history.removeAt(0);
    history.add(success ? rtt : -1.0);

    double minRtt = prev.minRttMs;
    double maxRtt = prev.maxRttMs;
    double avgRtt = prev.avgRttMs;
    double jitter = prev.jitterMs;

    if (success) {
      minRtt = (minRtt == 0.0 || rtt < minRtt) ? rtt : minRtt;
      maxRtt = rtt > maxRtt ? rtt : maxRtt;
      avgRtt = ((prev.avgRttMs * prev.receivedCount) + rtt) / newRecv;

      if (prev.lastRttMs > 0) {
        final diff = (rtt - prev.lastRttMs).abs();
        jitter = jitter + (diff - jitter) / 16.0;
      }
    }

    TargetStatus status;
    if (newLost >= 3 && success == false) {
      status = TargetStatus.offline;
    } else if (lossRate > 5.0 || (success && rtt > 180.0) || jitter > 30.0) {
      status = TargetStatus.degraded;
    } else {
      status = TargetStatus.online;
    }

    _latestMetrics[target.id] = PingMetric(
      id: target.id,
      name: target.name,
      host: target.host,
      port: target.port,
      protocol: target.protocol.label,
      status: status,
      sentCount: newSent,
      receivedCount: newRecv,
      lostCount: newLost,
      lossRate: lossRate,
      lastRttMs: success ? rtt : -1.0,
      minRttMs: minRtt,
      maxRttMs: maxRtt,
      avgRttMs: avgRtt,
      jitterMs: jitter,
      history: history,
      lastCheckedEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void dispose() {
    stop();
    if (_nativeEngine != null) {
      _bindings.freeEngine(_nativeEngine!);
      _nativeEngine = null;
    }
    _metricsController.close();
  }
}

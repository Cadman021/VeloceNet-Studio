import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import '../core/ffi/native_bindings.dart';
import '../models/ping_metric.dart';
import '../models/ping_target.dart';

/// Decodes a native metrics snapshot off the UI thread. Never throws:
/// malformed payloads yield an empty list and the UI keeps the previous
/// frame.
List<PingMetric> decodeMetricsSnapshot(String jsonStr) {
  try {
    final List<dynamic> list = jsonDecode(jsonStr);
    return list
        .whereType<Map<String, dynamic>>()
        .map(PingMetric.fromJson)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Single decode request for the worker isolate (plain data + a reply
/// port — both isolate-sendable).
class _DecodeRequest {
  final String json;
  final SendPort reply;
  const _DecodeRequest(this.json, this.reply);
}

/// Long-lived worker isolate entry point. A persistent isolate replaces the
/// previous `compute()`-per-tick design: spawning a fresh isolate every
/// 500ms costs milliseconds of spawn overhead plus GC churn on every poll.
void _decodeWorker(SendPort ready) {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((message) {
    final req = message as _DecodeRequest;
    req.reply.send(decodeMetricsSnapshot(req.json));
  });
}

class NetworkEngineService {
  final NativeBindings _bindings = NativeBindings();
  Pointer<Void>? _nativeEngine;
  bool _isRunning = false;
  Timer? _pollTimer;
  Timer? _fallbackTimer;
  // Guards overlapping decodes: if a previous snapshot is still being
  // decoded in the background isolate, the tick is skipped instead of
  // queueing up work (backpressure over latency).
  bool _decoding = false;
  Isolate? _decodeIsolate;
  SendPort? _decodePort;

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
    _fallbackBusy = false;
    _fallbackConsecFails.clear();
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
    _fallbackConsecFails.remove(targetId);

    if (isNativeAvailable && _nativeEngine != null) {
      _bindings.removeTarget(_nativeEngine!, targetId);
    }
  }

  Future<void> _ensureDecodeWorker() async {
    if (_decodePort != null) return;
    final ready = ReceivePort();
    _decodeIsolate =
        await Isolate.spawn(_decodeWorker, ready.sendPort);
    _decodePort = await ready.first as SendPort;
  }

  /// Decodes via the persistent worker isolate, falling back to inline
  /// decode if spawning or messaging ever fails.
  Future<List<PingMetric>> _decodeOffThread(String jsonStr) async {
    try {
      await _ensureDecodeWorker();
      final port = _decodePort;
      if (port == null) return decodeMetricsSnapshot(jsonStr);
      final reply = ReceivePort();
      port.send(_DecodeRequest(jsonStr, reply.sendPort));
      final result =
          await reply.first.timeout(const Duration(seconds: 5));
      reply.close();
      return (result as List).whereType<PingMetric>().toList();
    } catch (_) {
      return decodeMetricsSnapshot(jsonStr);
    }
  }

  Future<void> _pollNativeMetrics() async {
    if (_nativeEngine == null || _decoding || _metricsController.isClosed) return;
    final jsonStr = _bindings.getMetricsJson(_nativeEngine!);
    if (jsonStr == null || jsonStr.isEmpty) return;

    _decoding = true;
    try {
      final metrics = await _decodeOffThread(jsonStr);
      if (_metricsController.isClosed) return;
      if (metrics.isEmpty) {
        debugPrint('Metrics snapshot decoded empty; keeping previous frame.');
        return;
      }
      for (final m in metrics) {
        _latestMetrics[m.id] = m;
      }
      _metricsController.add(_latestMetrics.values.toList());
    } catch (e) {
      debugPrint('Error decoding metrics: $e');
    } finally {
      _decoding = false;
    }
  }

  // Consecutive (not lifetime) failures per target: offline status must
  // reflect the present, and must reset on any success.
  final Map<int, int> _fallbackConsecFails = {};
  // Reentrancy guard: a tick whose probes outlive the cadence must not
  // overlap the next one (double socket counts + read-modify-write races
  // on the metric history). Slow ticks are skipped instead of queued.
  bool _fallbackBusy = false;

  void _startDartFallbackProber() {
    _fallbackTimer?.cancel();
    // NOTE: fixed 800ms cadence; per-target `intervalMs` is honored only by
    // the native engine. The fallback favors simplicity over precision.
    _fallbackTimer = Timer.periodic(const Duration(milliseconds: 800), (_) async {
      if (!_isRunning || _fallbackBusy || _metricsController.isClosed) return;
      _fallbackBusy = true;
      try {
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
        if (!_metricsController.isClosed) {
          _metricsController.add(_latestMetrics.values.toList());
        }
      } finally {
        _fallbackBusy = false;
      }
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

    // Consecutive-failure tracking: a single failure after a long healthy
    // stretch must NOT flip the target offline (the old code compared
    // lifetime losses, so 3 total losses ever was enough, forever).
    final consec = success ? 0 : (_fallbackConsecFails[target.id] ?? 0) + 1;
    if (success) {
      _fallbackConsecFails.remove(target.id);
    } else {
      _fallbackConsecFails[target.id] = consec;
    }

    TargetStatus status;
    if (consec >= 3) {
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
    _decodeIsolate?.kill(priority: Isolate.immediate);
    _decodeIsolate = null;
    _decodePort = null;
    if (_nativeEngine != null) {
      _bindings.freeEngine(_nativeEngine!);
      _nativeEngine = null;
    }
    _metricsController.close();
  }
}

import 'dart:async';
import 'dart:convert';
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
  int _nativeEngine = 0;
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

  // Alert thresholds, mirrored to the native engine (when present) and
  // applied by the Dart fallback. Same defaults/semantics as stats.rs.
  int _alertOfflineAfter = 3;
  int _alertRecoverAfter = 2;

  void configureAlerts({required int offlineAfter, required int recoverAfter}) {
    _alertOfflineAfter = offlineAfter.clamp(1, 20);
    _alertRecoverAfter = recoverAfter.clamp(1, 20);
    _bindings.setAlertThresholds(_alertOfflineAfter, _alertRecoverAfter);
  }

  void initialize(List<PingTarget> initialTargets) {
    // Free any previous native engine to avoid leaking the Tokio runtime.
    // Safe to call synchronously: Engine::drop uses shutdown_background(),
    // so teardown never blocks the caller (see engine.rs).
    if (_nativeEngine != 0) {
      try {
        _bindings.stopEngine(_nativeEngine);
      } catch (_) {}
      try {
        _bindings.freeEngine(_nativeEngine);
      } catch (_) {}
      _nativeEngine = 0;
    }
    _pollTimer?.cancel();
    _fallbackTimer?.cancel();
    _fallbackBusy = false;
    _fallbackConsecFails.clear();
    _fallbackConsecSuccess.clear();
    _fallbackWasOffline.clear();
    _fallbackLastProbe.clear();
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
      if (_nativeEngine != 0) {
        for (final t in _targets) {
          if (t.isEnabled) {
            _bindings.addTarget(
              _nativeEngine,
              t.id,
              t.name,
              t.host,
              t.port,
              t.protocol.id,
              t.intervalMs,
              t.timeoutMs,
              t.httpPath,
            );
          }
        }
      }
    }
  }

  void start() {
    if (_isRunning) return;

    if (isNativeAvailable && _nativeEngine != 0) {
      final ok = _bindings.startEngine(_nativeEngine);
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

    if (isNativeAvailable && _nativeEngine != 0) {
      _bindings.stopEngine(_nativeEngine);
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

    if (isNativeAvailable && _nativeEngine != 0 && target.isEnabled) {
      _bindings.addTarget(
        _nativeEngine,
        target.id,
        target.name,
        target.host,
        target.port,
        target.protocol.id,
        target.intervalMs,
        target.timeoutMs,
        target.httpPath,
      );
    }
  }

  void removeTarget(int targetId) {
    _targets.removeWhere((t) => t.id == targetId);
    _latestMetrics.remove(targetId);
    _fallbackConsecFails.remove(targetId);
    _fallbackConsecSuccess.remove(targetId);
    _fallbackWasOffline.remove(targetId);
    _fallbackLastProbe.remove(targetId);

    if (isNativeAvailable && _nativeEngine != 0) {
      _bindings.removeTarget(_nativeEngine, targetId);
    }
  }

  Future<void> _ensureDecodeWorker() async {
    if (_decodePort != null) return;
    final ready = ReceivePort();
    _decodeIsolate = await Isolate.spawn(_decodeWorker, ready.sendPort);
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
      final result = await reply.first.timeout(const Duration(seconds: 5));
      reply.close();
      return (result as List).whereType<PingMetric>().toList();
    } catch (_) {
      return decodeMetricsSnapshot(jsonStr);
    }
  }

  Future<void> _pollNativeMetrics() async {
    if (_nativeEngine == 0 || _decoding || _metricsController.isClosed) {
      return;
    }
    final jsonStr = _bindings.getMetricsJson(_nativeEngine);
    if (jsonStr == null || jsonStr.isEmpty) return;

    _decoding = true;
    try {
      final metrics = await _decodeOffThread(jsonStr);
      if (_metricsController.isClosed) return;
      // Race guard: a target removed while its snapshot was in flight must
      // not be resurrected — accept only ids still present in _targets.
      final liveIds = _targets.map((t) => t.id).toSet();
      if (_targets.isEmpty) {
        // All targets gone: clear instead of keeping a stale frame.
        if (_latestMetrics.isNotEmpty) {
          _latestMetrics.clear();
          _metricsController.add(const []);
        }
        return;
      }
      if (metrics.isEmpty) {
        debugPrint('Metrics snapshot decoded empty; keeping previous frame.');
        return;
      }
      for (final m in metrics) {
        if (liveIds.contains(m.id)) {
          _latestMetrics[m.id] = m;
        }
      }
      _latestMetrics.removeWhere((id, _) => !liveIds.contains(id));
      _metricsController.add(_latestMetrics.values.toList());
    } catch (e) {
      debugPrint('Error decoding metrics: $e');
    } finally {
      _decoding = false;
    }
  }

  // Consecutive (not lifetime) failures per target: offline status must
  // reflect the present, and must reset on any success. Plus the recovery
  // side of hysteresis (mirrors stats.rs): sticky was-offline memory plus
  // a consecutive-success counter.
  final Map<int, int> _fallbackConsecFails = {};
  final Map<int, int> _fallbackConsecSuccess = {};
  final Set<int> _fallbackWasOffline = {};
  // Reentrancy guard: a tick whose probes outlive the cadence must not
  // overlap the next one (double socket counts + read-modify-write races
  // on the metric history). Slow ticks are skipped instead of queued.
  bool _fallbackBusy = false;

  // Last probe start per target: the fallback honors each target's own
  // intervalMs (like the native engine) instead of probing everything on
  // a fixed cadence.
  final Map<int, DateTime> _fallbackLastProbe = {};

  void _startDartFallbackProber() {
    _fallbackTimer?.cancel();
    _fallbackTimer =
        Timer.periodic(const Duration(milliseconds: 800), (_) async {
      if (!_isRunning || _fallbackBusy || _metricsController.isClosed) return;
      _fallbackBusy = true;
      try {
        final now = DateTime.now();
        final futures = _targets.where((t) => t.isEnabled).map((target) async {
          final interval =
              Duration(milliseconds: target.intervalMs.clamp(200, 60000));
          final last = _fallbackLastProbe[target.id];
          // First probe immediately; afterwards only when due. Timestamp is
          // set BEFORE probing so a slow probe can't pile up overlaps.
          if (last != null && now.difference(last) < interval) return;
          _fallbackLastProbe[target.id] = now;
          final result = await _probeTarget(target);
          _updateFallbackMetric(
            target,
            result.success,
            result.rttMs,
            httpStatus: result.httpStatus,
            certDaysLeft: result.certDaysLeft,
          );
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

  Future<_FallbackProbeResult> _probeTarget(PingTarget target) {
    return target.protocol.isHttp ? _probeHttp(target) : _probeTcp(target);
  }

  // ICMP shares the TCP-connect path here (as before): the fallback prober
  // only exists when the native engine (real ICMP/TCP/HTTP) is unavailable.
  Future<_FallbackProbeResult> _probeTcp(PingTarget target) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        target.host,
        target.port > 0 ? target.port : 80,
        timeout: Duration(milliseconds: target.timeoutMs),
      );
      stopwatch.stop();
      final rtt = stopwatch.elapsedMicroseconds / 1000.0;
      socket.destroy();
      return _FallbackProbeResult(success: true, rttMs: rtt);
    } catch (_) {
      return const _FallbackProbeResult(success: false, rttMs: -1.0);
    }
  }

  /// Mirrors the native HTTP(S) probe: TTFB is stamped on the first response
  /// byte, 4xx/5xx are failures but still report their status, and any
  /// certificate is accepted so an expired/self-signed cert is reported
  /// instead of hiding the endpoint's latency.
  Future<_FallbackProbeResult> _probeHttp(PingTarget target) async {
    final tls = target.protocol == NetworkProtocol.https;
    final port = target.port > 0 ? target.port : target.protocol.defaultPort;
    final timeout = Duration(milliseconds: target.timeoutMs);
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      if (tls) {
        socket = await SecureSocket.connect(
          target.host,
          port,
          timeout: timeout,
          onBadCertificate: (_) => true,
        );
      } else {
        socket = await Socket.connect(target.host, port, timeout: timeout);
      }
      final path = target.httpPath.isEmpty ? '/' : target.httpPath;
      final hostHeader =
          (port == 80 || port == 443) ? target.host : '${target.host}:$port';
      socket.write('GET $path HTTP/1.1\r\n'
          'Host: $hostHeader\r\n'
          'User-Agent: VeloceNetStudio\r\n'
          'Accept: */*\r\n'
          'Connection: close\r\n\r\n');
      await socket.flush();
      final first = await socket.first.timeout(timeout);
      stopwatch.stop();
      final rtt = stopwatch.elapsedMicroseconds / 1000.0;
      final match = RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})')
          .firstMatch(String.fromCharCodes(first));
      final status = match == null ? null : int.tryParse(match.group(1)!);
      int? certDays;
      if (socket is SecureSocket) {
        final endValidity = socket.peerCertificate?.endValidity;
        if (endValidity != null) {
          certDays = (endValidity.difference(DateTime.now()).inSeconds / 86400)
              .floor();
        }
      }
      return _FallbackProbeResult(
        success: status != null && status < 400,
        rttMs: status == null ? -1.0 : rtt,
        httpStatus: status,
        certDaysLeft: certDays,
      );
    } catch (_) {
      return const _FallbackProbeResult(success: false, rttMs: -1.0);
    } finally {
      socket?.destroy();
    }
  }

  void _updateFallbackMetric(
    PingTarget target,
    bool success,
    double rtt, {
    int? httpStatus,
    int? certDaysLeft,
  }) {
    final prev = _latestMetrics[target.id] ??
        PingMetric.initial(target.id, target.name, target.host, target.port,
            target.protocol.label);

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
    final consecSucc =
        success ? (_fallbackConsecSuccess[target.id] ?? 0) + 1 : 0;
    if (success) {
      _fallbackConsecFails.remove(target.id);
      _fallbackConsecSuccess[target.id] = consecSucc;
    } else {
      _fallbackConsecFails[target.id] = consec;
      _fallbackConsecSuccess.remove(target.id);
    }

    // Windowed loss over the capped history (mirrors the native engine's
    // 40-sample ring): lifetime loss would pin a target Degraded forever
    // after a few ancient failures.
    final wLost = history.where((v) => v < 0).length;
    final wLoss = history.isEmpty ? 0.0 : wLost / history.length * 100.0;

    // Same hysteresis as stats.rs: configurable trip point, sticky
    // was-offline memory, recovery gated on consecutive successes.
    TargetStatus status;
    if (consec >= _alertOfflineAfter) {
      _fallbackWasOffline.add(target.id);
      status = TargetStatus.offline;
    } else if (_fallbackWasOffline.contains(target.id) &&
        consecSucc < _alertRecoverAfter) {
      status = TargetStatus.degraded;
    } else if (wLoss > 50.0) {
      _fallbackWasOffline.add(target.id);
      status = TargetStatus.offline;
    } else if (wLoss > 5.0 || (success && rtt > 180.0) || jitter > 30.0) {
      status = TargetStatus.degraded;
    } else {
      _fallbackWasOffline.remove(target.id);
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
      httpStatus: httpStatus,
      // Native semantics: only overwrite cert info when a new TLS sample
      // actually observed it (a transient handshake failure must not hide
      // a known expiry date).
      certDaysLeft: certDaysLeft ?? prev.certDaysLeft,
    );
  }

  void dispose() {
    stop();
    _decodeIsolate?.kill(priority: Isolate.immediate);
    _decodeIsolate = null;
    _decodePort = null;
    if (_nativeEngine != 0) {
      _bindings.freeEngine(_nativeEngine);
      _nativeEngine = 0;
    }
    _metricsController.close();
  }
}

class _FallbackProbeResult {
  final bool success;
  final double rttMs;
  final int? httpStatus;
  final int? certDaysLeft;

  const _FallbackProbeResult({
    required this.success,
    required this.rttMs,
    this.httpStatus,
    this.certDaysLeft,
  });
}

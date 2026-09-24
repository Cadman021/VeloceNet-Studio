import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/ping_metric.dart';
import '../models/ping_target.dart';
import '../services/network_engine_service.dart';
import '../services/preset_targets.dart';
import 'alert_log.dart';

class PingMatrixController extends ChangeNotifier {
  final NetworkEngineService _service = NetworkEngineService();
  StreamSubscription<List<PingMetric>>? _metricsSub;
  final AlertLog alertLog = AlertLog();

  List<PingTarget> _targets = [];
  final Map<int, PingMetric> _metrics = {};
  bool _isMonitoring = false;

  List<PingTarget> get targets => _targets;
  Map<int, PingMetric> get metrics => _metrics;
  bool get isMonitoring => _isMonitoring;
  bool get isNativeEngineActive => _service.isNativeAvailable;

  int get totalTargets => _targets.length;

  int get onlineCount => _metrics.values
      .where((m) => m.status == TargetStatus.online)
      .length;

  int get degradedCount => _metrics.values
      .where((m) => m.status == TargetStatus.degraded)
      .length;

  int get offlineCount => _metrics.values
      .where((m) => m.status == TargetStatus.offline)
      .length;

  double get averageLatency {
    final active = _metrics.values.where((m) => m.lastRttMs > 0).toList();
    if (active.isEmpty) return 0.0;
    final sum = active.map((m) => m.lastRttMs).reduce((a, b) => a + b);
    return sum / active.length;
  }

  double get averageJitter {
    final active = _metrics.values.where((m) => m.jitterMs > 0).toList();
    if (active.isEmpty) return 0.0;
    final sum = active.map((m) => m.jitterMs).reduce((a, b) => a + b);
    return sum / active.length;
  }

  double get overallPacketLoss {
    int totalSent = 0;
    int totalLost = 0;
    for (final m in _metrics.values) {
      totalSent += m.sentCount;
      totalLost += m.lostCount;
    }
    if (totalSent == 0) return 0.0;
    return (totalLost / totalSent) * 100.0;
  }

  void init() {
    _targets = PresetTargets.getDefaultTargets();
    _service.initialize(_targets);

    _metricsSub = _service.metricsStream.listen((list) {
      for (final m in list) {
        final prev = _metrics[m.id];
        if (prev != null && prev.status != m.status) {
          final target = _targets.where((t) => t.id == m.id);
          alertLog.noteTransition(
            targetId: m.id,
            targetName:
                target.isEmpty ? m.name : target.first.name,
            from: prev.status,
            to: m.status,
            rttMs: m.lastRttMs,
            lossRate: m.lossRate,
          );
        }
        _metrics[m.id] = m;
      }
      notifyListeners();
    });

    // Start automatically
    start();
  }

  void start() {
    _isMonitoring = true;
    _service.start();
    notifyListeners();
  }

  void pause() {
    _isMonitoring = false;
    _service.stop();
    notifyListeners();
  }

  void toggleMonitoring() {
    if (_isMonitoring) {
      pause();
    } else {
      start();
    }
  }

  void addTarget(PingTarget target) {
    _targets.add(target);
    _service.addTarget(target);
    notifyListeners();
  }

  void removeTarget(int id) {
    _targets.removeWhere((t) => t.id == id);
    _metrics.remove(id);
    _service.removeTarget(id);
    notifyListeners();
  }

  void resetMetrics() {
    _service.stop();
    _metrics.clear();
    for (final t in _targets) {
      _metrics[t.id] = PingMetric.initial(
        t.id,
        t.name,
        t.host,
        t.port,
        t.protocol.label,
      );
    }
    _service.initialize(_targets);
    if (_isMonitoring) {
      _service.start();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _metricsSub?.cancel();
    _service.dispose();
    super.dispose();
  }
}

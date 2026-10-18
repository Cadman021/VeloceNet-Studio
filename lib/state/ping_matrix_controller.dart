import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ping_metric.dart';
import '../models/ping_target.dart';
import '../services/network_engine_service.dart';
import '../services/preset_targets.dart';
import '../services/target_config_io.dart';
import '../services/uptime_history.dart';
import 'alert_log.dart';

class PingMatrixController extends ChangeNotifier {
  final NetworkEngineService _service = NetworkEngineService();
  StreamSubscription<List<PingMetric>>? _metricsSub;
  final AlertLog alertLog = AlertLog();
  final UptimeHistoryService historyService = UptimeHistoryService();

  List<PingTarget> _targets = [];
  final Map<int, PingMetric> _metrics = {};
  bool _isMonitoring = false;

  List<PingTarget> get targets => _targets;
  Map<int, PingMetric> get metrics => _metrics;
  bool get isMonitoring => _isMonitoring;
  bool get isNativeEngineActive => _service.isNativeAvailable;

  int get totalTargets => _targets.length;

  int get onlineCount =>
      _metrics.values.where((m) => m.status == TargetStatus.online).length;

  int get degradedCount =>
      _metrics.values.where((m) => m.status == TargetStatus.degraded).length;

  int get offlineCount =>
      _metrics.values.where((m) => m.status == TargetStatus.offline).length;

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

  static const _kPersistedTargets = 'targets.v1';

  /// Loads persisted user targets (falling back to presets on first run
  /// or corrupt data), then wires the engine. Async: prefs read + notify
  /// once targets are known so the grid never shows stale defaults first.
  Future<void> init() async {
    List<PingTarget>? restored;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPersistedTargets);
      if (raw != null) restored = decodePersistedTargets(raw);
    } catch (_) {}
    // Growable copy: presets come back as a const (unmodifiable) list and
    // add/remove would throw on it — this crashed "Add server" outright.
    _targets = List.of(restored ?? PresetTargets.getDefaultTargets());
    _service.initialize(_targets);
    // Best-effort history; frames before init completes are skipped.
    unawaited(historyService.init());

    _metricsSub = _service.metricsStream.listen((list) {
      for (final m in list) {
        final prev = _metrics[m.id];
        if (prev != null && prev.status != m.status) {
          final matches = _targets.where((t) => t.id == m.id);
          final target = matches.isEmpty ? null : matches.first;
          if (target == null || target.muted) continue;
          alertLog.noteTransition(
            targetId: m.id,
            targetName: target.name,
            from: prev.status,
            to: m.status,
            rttMs: m.lastRttMs,
            lossRate: m.lossRate,
          );
        }
        _metrics[m.id] = m;
      }
      // Fire-and-forget: aggregation is synchronous; only minute rollover
      // touches disk, off the critical rebuild path.
      unawaited(historyService.recordFrame(_metrics));
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
    _persistTargets();
    notifyListeners();
  }

  void removeTarget(int id) {
    _targets.removeWhere((t) => t.id == id);
    _metrics.remove(id);
    _service.removeTarget(id);
    _persistTargets();
    notifyListeners();
  }

  /// Flips the maintenance mute: muted targets keep probing (metrics stay
  /// live) but emit no alert events and no webhooks.
  void toggleMute(int id) {
    final i = _targets.indexWhere((t) => t.id == id);
    if (i == -1) return;
    _targets[i] = _targets[i].copyWith(muted: !_targets[i].muted);
    _persistTargets();
    notifyListeners();
  }

  /// Replaces an existing target in place (edit flow) — id and metrics
  /// continuity are preserved. Unknown ids are ignored.
  void updateTarget(PingTarget target) {
    final i = _targets.indexWhere((t) => t.id == target.id);
    if (i == -1) return;
    _targets[i] = target;
    // Service.addTarget removes the same-id entry before adding, so the
    // live prober picks up the edited fields on the next frame.
    _service.addTarget(target);
    _persistTargets();
    notifyListeners();
  }

  /// Applies alert thresholds to the prober (native engine + fallback).
  void configureAlerts({required int offlineAfter, required int recoverAfter}) {
    _service.configureAlerts(
      offlineAfter: offlineAfter,
      recoverAfter: recoverAfter,
    );
  }

  /// Best-effort persistence after every user mutation (add/remove/import).
  /// Mutations are user-driven (rare), so no debounce is needed; failures
  /// only log.
  void _persistTargets() {
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kPersistedTargets, exportTargetsJson(_targets));
      } catch (e) {
        debugPrint('Target persistence failed: $e');
      }
    }());
  }

  /// Adds imported drafts, reassigning collision-free ids above the current
  /// maximum (stored backup ids are ignored). Returns the number added.
  int importTargets(List<PingTarget> drafts) {
    int nextId = _targets.isEmpty
        ? 1
        : _targets.map((t) => t.id).reduce((a, b) => a > b ? a : b) + 1;
    for (final d in drafts) {
      final target = d.copyWith(id: nextId++);
      _targets.add(target);
      _service.addTarget(target);
    }
    _persistTargets();
    notifyListeners();
    return drafts.length;
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
    unawaited(historyService.flush());
    _service.dispose();
    super.dispose();
  }
}

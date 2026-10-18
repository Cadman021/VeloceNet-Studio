import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/validation/host_validator.dart';
import '../../models/ping_metric.dart';
import '../../models/ping_target.dart';
import '../../models/traceroute_hop.dart';
import '../../services/network_engine_service.dart';
import '../traceroute/traceroute_controller.dart';

/// Hop monitor ids live far above matrix/warp ranges (millis/1000+), so the
/// dedicated engine below can never collide with user targets.
const int kMtrIdBase = 900000;

/// Monitor-target id for a hop number (shared with the screen layer).
int mtrHopId(int hopNum) => kMtrIdBase + hopNum;

/// MTR = traceroute once, then ping every discovered hop continuously.
///
/// Phase 1 (discovery) reuses [TracerouteController] (native on Windows,
/// system binary elsewhere). Phase 2 (monitoring) runs a dedicated
/// [NetworkEngineService] with one ICMP target per responding hop, so a
/// restart of the matrix tab can never disturb it and vice versa.
///
/// Timeout (`*`) hops carry no address and are shown statically — there is
/// nothing to probe.
class MtrController extends ChangeNotifier {
  final TracerouteController tracer = TracerouteController();
  final NetworkEngineService _ping = NetworkEngineService();
  StreamSubscription<List<PingMetric>>? _metricsSub;

  final Map<int, PingMetric> hopMetrics = {};
  bool _monitoring = false;
  bool _discovering = false;

  bool get isRunning => _discovering || _monitoring;
  bool get isDiscovering => _discovering;
  bool get isMonitoring => _monitoring;
  List<TracerouteHop> get hops => tracer.hops;

  MtrController() {
    tracer.addListener(_onTraceUpdate);
    _metricsSub = _ping.metricsStream.listen((list) {
      var changed = false;
      for (final m in list) {
        hopMetrics[m.id] = m;
        changed = true;
      }
      if (changed) notifyListeners();
    });
  }

  /// Pure hop → monitor-target mapping (unit tested, no I/O).
  static List<PingTarget> buildHopTargets(
    List<TracerouteHop> hops, {
    int intervalMs = 1000,
    int timeoutMs = 1500,
  }) {
    final out = <PingTarget>[];
    for (final h in hops) {
      if (h.isTimeout || h.ip == '*') continue;
      out.add(PingTarget(
        id: mtrHopId(h.hopNum),
        name: 'Hop ${h.hopNum} (${h.ip})',
        host: h.ip,
        port: 80, // unused by ICMP probes; satisfies FFI validation
        protocol: NetworkProtocol.icmp,
        intervalMs: intervalMs,
        timeoutMs: timeoutMs,
      ));
    }
    return out;
  }

  void start(String rawHost) {
    final host = normalizeTraceHost(rawHost);
    if (host == null) return;
    stop();
    _monitoring = false;
    _discovering = true;
    hopMetrics.clear();
    notifyListeners();
    tracer.start(host);
  }

  void _onTraceUpdate() {
    if (!_discovering) return;
    final progress = tracer.progress;
    // Wait for the terminal state; partial hops are displayed live by the
    // traceroute tab pattern, but monitoring starts on the full path.
    if (!progress.isCompleted) {
      notifyListeners(); // phase-1 progress (hop count) for the header
      return;
    }
    _discovering = false;
    final targets = buildHopTargets(progress.hops);
    if (targets.isEmpty) {
      notifyListeners();
      return;
    }
    _ping.initialize(targets);
    _ping.start();
    _monitoring = true;
    notifyListeners();
  }

  void stop() {
    _discovering = false;
    _monitoring = false;
    tracer.stop();
    _ping.stop();
    notifyListeners();
  }

  void clear() {
    stop();
    hopMetrics.clear();
    tracer.reset();
    notifyListeners();
  }

  @override
  void dispose() {
    tracer.removeListener(_onTraceUpdate);
    tracer.dispose();
    _metricsSub?.cancel();
    _ping.dispose();
    super.dispose();
  }
}

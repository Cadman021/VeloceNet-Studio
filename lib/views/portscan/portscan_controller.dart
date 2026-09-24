import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../models/port_scan.dart';
import '../traceroute/traceroute_controller.dart';

/// TCP port sweeper (pure Dart, no native engine needed).
///
/// Ports are probed in bounded-concurrency batches; cancellation is
/// cooperative between batches (in-flight connects finish via their
/// timeout). A timed-out connect is reported as `filtered`, a refused
/// one as `closed` — the standard heuristic, documented in the UI.
class PortscanController extends ChangeNotifier {
  static const int maxPorts = 4096;

  final List<PortScanResult> _results = [];
  bool _isRunning = false;
  bool _isCompleted = false;
  String? _error;
  String _targetHost = '';
  int _runId = 0;

  List<PortScanResult> get results => List.unmodifiable(_results);
  bool get isRunning => _isRunning;
  bool get isCompleted => _isCompleted;
  String? get error => _error;
  String get targetHost => _targetHost;
  int get total => _results.length;
  int get openCount => _results.where((r) => r.state == PortState.open).length;

  List<PortScanResult> get openPorts =>
      _results.where((r) => r.state == PortState.open).toList();

  void start(
    String rawHost,
    String portsSpec, {
    int timeoutMs = 1000,
    int concurrency = 64,
  }) {
    final host = TracerouteController.normalizeTraceHost(rawHost);
    if (host == null) {
      _error = 'Invalid host. Use an IPv4/IPv6 address or hostname.';
      notifyListeners();
      return;
    }
    final ports = parsePortSpec(portsSpec, maxPorts: maxPorts);
    if (ports == null) {
      _error = 'Invalid port list (1-65535, max $maxPorts ports).';
      notifyListeners();
      return;
    }

    stop();
    final int runId = ++_runId;
    _results.clear();
    _error = null;
    _targetHost = host;
    _isRunning = true;
    _isCompleted = false;
    notifyListeners();

    _run(
      host,
      ports,
      timeoutMs.clamp(100, 5000),
      concurrency.clamp(1, 256),
      runId,
    );
  }

  Future<void> _run(
    String host,
    List<int> ports,
    int timeoutMs,
    int concurrency,
    int runId,
  ) async {
    for (int i = 0; i < ports.length; i += concurrency) {
      if (runId != _runId) return; // stopped or superseded
      final batch = ports.skip(i).take(concurrency);
      final out = await Future.wait(
        batch.map((p) => _probe(host, p, timeoutMs)),
      );
      if (runId != _runId) return;
      _results.addAll(out);
      notifyListeners();
    }
    if (runId != _runId) return;
    _isRunning = false;
    _isCompleted = true;
    notifyListeners();
  }

  Future<PortScanResult> _probe(String host, int port, int timeoutMs) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: Duration(milliseconds: timeoutMs),
      );
      stopwatch.stop();
      final rtt = stopwatch.elapsedMicroseconds / 1000.0;
      try {
        await socket.close();
      } catch (_) {
        socket.destroy();
      }
      return PortScanResult(
        port: port,
        state: PortState.open,
        service: serviceForPort(port),
        rttMs: rtt,
      );
    } on TimeoutException {
      stopwatch.stop();
      return PortScanResult(
        port: port,
        state: PortState.filtered,
        service: serviceForPort(port),
        rttMs: -1.0,
      );
    } catch (_) {
      // Connection refused/reset and DNS failures land here; for a
      // sweep this overwhelmingly means "closed".
      stopwatch.stop();
      return PortScanResult(
        port: port,
        state: PortState.closed,
        service: serviceForPort(port),
        rttMs: -1.0,
      );
    }
  }

  void stop() {
    _runId++;
    if (_isRunning) {
      _isRunning = false;
      _isCompleted = true;
      notifyListeners();
    }
  }

  void clear() {
    stop();
    _results.clear();
    _error = null;
    _isCompleted = false;
    _targetHost = '';
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

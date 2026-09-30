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

  Future<void> start(
    String rawHost,
    String portsSpec, {
    int timeoutMs = 1000,
    int concurrency = 64,
  }) async {
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

    // Resolve ONCE up front: resolving per port would multiply DNS traffic
    // by the port count (thousands of identical lookups).
    List<InternetAddress> addrs;
    try {
      addrs = await InternetAddress.lookup(host)
          .timeout(Duration(milliseconds: timeoutMs.clamp(100, 5000)));
    } catch (_) {
      if (runId != _runId) return;
      _error = 'DNS resolution failed.';
      _isRunning = false;
      _isCompleted = true;
      notifyListeners();
      return;
    }
    if (runId != _runId || addrs.isEmpty) return;

    _run(
      addrs.first,
      ports,
      timeoutMs.clamp(100, 5000),
      concurrency.clamp(1, 256),
      runId,
    );
  }

  Future<void> _run(
    InternetAddress addr,
    List<int> ports,
    int timeoutMs,
    int concurrency,
    int runId,
  ) async {
    for (int i = 0; i < ports.length; i += concurrency) {
      if (runId != _runId) return; // stopped or superseded
      final batch = ports.skip(i).take(concurrency);
      final out = await Future.wait(
        batch.map((p) => _probe(addr, p, timeoutMs)),
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

  Future<PortScanResult> _probe(
      InternetAddress addr, int port, int timeoutMs) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        addr,
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
    } on SocketException catch (e) {
      // NOTE: `Socket.connect`'s `timeout` surfaces as SocketException,
      // never TimeoutException (verified empirically) — so refused vs timed
      // out must be distinguished here, by OS error code with a message
      // fallback for platforms without a distinct code.
      stopwatch.stop();
      final filtered = _isTimeoutError(e);
      return PortScanResult(
        port: port,
        state: filtered ? PortState.filtered : PortState.closed,
        service: serviceForPort(port),
        rttMs: -1.0,
      );
    } catch (_) {
      stopwatch.stop();
      return PortScanResult(
        port: port,
        state: PortState.closed,
        service: serviceForPort(port),
        rttMs: -1.0,
      );
    }
  }

  /// WSAETIMEDOUT (Windows), ETIMEDOUT (Linux/macOS) + message fallback.
  static bool _isTimeoutError(SocketException e) {
    const timeoutCodes = {10060, 110, 60};
    final code = e.osError?.errorCode;
    if (code != null && timeoutCodes.contains(code)) return true;
    return e.message.toLowerCase().contains('timed out');
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

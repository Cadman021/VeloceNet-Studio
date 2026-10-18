import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/validation/host_validator.dart';
import '../../models/port_scan.dart';

/// TCP port sweeper (pure Dart, no native engine needed).
///
/// A fixed-size worker pool drains the port queue (no batch barriers: a slow
/// port never idles the other workers). Each port is tried against every
/// resolved address; it is `open` if any address accepts, `filtered` if all
/// attempts time out, otherwise `closed`. Cancellation is cooperative: the
/// in-flight connects finish via their timeout, then the workers stop.
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
    final host = normalizeTraceHost(rawHost);
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
    if (runId != _runId) return;
    if (addrs.isEmpty) {
      _error = 'DNS resolution failed.';
      _isRunning = false;
      _isCompleted = true;
      notifyListeners();
      return;
    }

    _run(
      addrs,
      ports,
      timeoutMs.clamp(100, 5000),
      concurrency.clamp(1, 256),
      runId,
    );
  }

  Future<void> _run(
    List<InternetAddress> addrs,
    List<int> ports,
    int timeoutMs,
    int concurrency,
    int runId,
  ) async {
    var next = 0;
    var completed = 0;

    Future<void> worker() async {
      while (true) {
        if (runId != _runId) return; // stopped or superseded
        final index = next++;
        if (index >= ports.length) return;
        final result = await _probePort(addrs, ports[index], timeoutMs);
        if (runId != _runId) return;
        _results.add(result);
        completed++;
        // Throttle rebuilds: with thousands of ports, notifying per result
        // would re-render the screen hundreds of times per second.
        if (completed % 16 == 0 || completed == ports.length) {
          notifyListeners();
        }
      }
    }

    final workers = concurrency < ports.length ? concurrency : ports.length;
    await Future.wait(List.generate(workers, (_) => worker()));
    if (runId != _runId) return;

    // Completion order is nondeterministic; sort so the table and exports
    // stay stable across runs.
    _results.sort((a, b) => a.port.compareTo(b.port));
    _isRunning = false;
    _isCompleted = true;
    notifyListeners();
  }

  /// Probes one port on all resolved addresses concurrently (a dual-stack
  /// name should report open if either family accepts). Timeouts are
  /// concurrent, so one port costs at most one timeout period.
  Future<PortScanResult> _probePort(
    List<InternetAddress> addrs,
    int port,
    int timeoutMs,
  ) async {
    final attempts = await Future.wait(
      addrs.map((addr) => _probe(addr, port, timeoutMs)),
    );
    for (final result in attempts) {
      if (result.state == PortState.open) {
        return PortScanResult(
          port: port,
          state: PortState.open,
          service: serviceForPort(port),
          rttMs: result.rttMs,
        );
      }
    }
    final sawTimeout =
        attempts.any((result) => result.state == PortState.filtered);
    return PortScanResult(
      port: port,
      state: sawTimeout ? PortState.filtered : PortState.closed,
      service: serviceForPort(port),
      rttMs: -1.0,
    );
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

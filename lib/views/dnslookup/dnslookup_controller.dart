import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../services/dns_client.dart';
import '../traceroute/traceroute_controller.dart';

/// Preset DNS servers (IP literals — the raw UDP client needs no resolver).
const Map<String, String> kDnsServers = {
  'Cloudflare': '1.1.1.1',
  'Google': '8.8.8.8',
  'Quad9': '9.9.9.9',
};

/// DNS lookup tool state. Queries run over raw UDP; cancellation is
/// cooperative via a generation counter (a late packet never overwrites a
/// newer query's results).
class DnslookupController extends ChangeNotifier {
  DnsResponse? _response;
  bool _isRunning = false;
  bool _isCompleted = false;
  String? _error;
  String _target = '';
  int _runId = 0;

  DnsResponse? get response => _response;
  bool get isRunning => _isRunning;
  bool get isCompleted => _isCompleted;
  String? get error => _error;
  String get target => _target;
  List<DnsRecord> get records => _response?.answers ?? const [];

  Future<void> query({
    required String rawHost,
    required DnsQueryType qtype,
    required String serverIp,
    int timeoutMs = 2000,
  }) async {
    final host = TracerouteController.normalizeTraceHost(rawHost);
    if (host == null) {
      _error = 'Invalid domain. Use a hostname or IP literal.';
      notifyListeners();
      return;
    }
    if (InternetAddress.tryParse(serverIp.trim()) == null) {
      _error = 'Invalid DNS server IP.';
      notifyListeners();
      return;
    }

    stop();
    final int runId = ++_runId;
    _response = null;
    _error = null;
    _target = host;
    _isRunning = true;
    _isCompleted = false;
    notifyListeners();

    try {
      final resp = await lookupDns(
        name: host,
        qtype: qtype,
        serverIp: serverIp.trim(),
        timeoutMs: timeoutMs.clamp(300, 10000),
      );
      if (runId != _runId) return;
      _response = resp;
      _isRunning = false;
      _isCompleted = true;
    } on DnsNxDomain {
      if (runId != _runId) return;
      _error = 'Domain does not exist (NXDOMAIN).';
      _isRunning = false;
      _isCompleted = true;
    } on TimeoutException catch (e) {
      if (runId != _runId) return;
      _error = e.message ?? 'Query timed out.';
      _isRunning = false;
      _isCompleted = true;
    } on DnsException catch (e) {
      if (runId != _runId) return;
      _error = e.message;
      _isRunning = false;
      _isCompleted = true;
    } catch (e) {
      if (runId != _runId) return;
      debugPrint('DNS lookup failed: $e');
      _error = 'Query failed.';
      _isRunning = false;
      _isCompleted = true;
    }
    notifyListeners();
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
    _response = null;
    _error = null;
    _isCompleted = false;
    _target = '';
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

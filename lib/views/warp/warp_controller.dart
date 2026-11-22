import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/ffi/native_bindings.dart';
import '../../models/ping_target.dart';
import '../../models/warp_endpoint.dart';
import '../../models/warp_profile.dart';
import '../../models/warp_result.dart';
import 'warp_socket.dart' as ws;

/// Controls a Warp endpoint scan.
///
/// Stability rules (learned from the traceroute phase on Windows desktop):
/// - Native Rust scan (UDP probe + TCP fallback) when FFI is ready.
/// - Dart fallback (TCP connect per endpoint, chunked by [parallel]).
/// - Poll at 500ms, notify listeners ONLY when tested-count changed.
class WarpController extends ChangeNotifier {
  final NativeBindings _bindings = NativeBindings();

  WarpProgress _progress = WarpProgress.empty();
  Timer? _pollTimer;
  int _activeSessionId = 0;
  bool _cancelFallback = false;
  bool? _isUsingNativeOverride;
  // Generation counter: starting a new scan while a Dart fallback loop is
  // still awaiting a chunk would otherwise let the old loop keep writing
  // into the new run's progress (same stale-write race class as fixed in
  // the traceroute/portscan/dns controllers).
  int _runId = 0;

  // --- Imported WireGuard profile (session-only, never persisted) ---
  WarpProfile? _profile;
  String? _profileError;
  bool _useProfileForScan = true;
  bool _validatingProfile = false;
  WarpProfileValidation? _profileValidation;
  int _validationRunId = 0;
  bool _disposed = false;

  WarpProfile? get profile => _profile;
  String? get profileError => _profileError;
  bool get useProfileForScan => _useProfileForScan;
  bool get isValidatingProfile => _validatingProfile;
  WarpProfileValidation? get profileValidation => _profileValidation;
  bool get profileSupported => _bindings.isWarpProfileReady;

  /// Actual probe path of the current/last run; falls back to mere
  /// availability before the first scan.
  bool get isUsingNative => _isUsingNativeOverride ?? isNativeAvailable;

  // --- User selections ---
  final Set<String> selectedRangeIds = {
    WarpCatalog.ranges[0].id,
    WarpCatalog.ranges[1].id,
  };
  final Set<int> selectedPorts = {WarpCatalog.defaultPort};
  int parallel = 32;
  int timeoutMs = 1200;

  WarpProgress get progress => _progress;
  bool get isRunning => _progress.isRunning;
  bool get isNativeAvailable => _bindings.isWarpReady;
  int get nextPingTargetIdStart => 1000;

  /// Expanded "ip" list from selected ranges.
  List<String> expandSelectedIps() {
    final out = <String>[];
    for (final r in WarpCatalog.ranges) {
      if (selectedRangeIds.contains(r.id)) out.addAll(r.expandIps());
    }
    return out;
  }

  /// Expanded "ip:port" list (cartesian product).
  List<String> expandEndpoints() {
    final out = <String>[];
    final ports = selectedPorts.isEmpty
        ? [WarpCatalog.defaultPort]
        : selectedPorts.toList()
      ..sort();
    for (final ip in expandSelectedIps()) {
      for (final p in ports) {
        out.add('$ip:$p');
      }
    }
    return out;
  }

  int get plannedCount =>
      expandSelectedIps().length *
      (selectedPorts.isEmpty ? 1 : selectedPorts.length);

  void toggleRange(String id) {
    if (selectedRangeIds.contains(id)) {
      if (selectedRangeIds.length > 1) selectedRangeIds.remove(id);
    } else {
      selectedRangeIds.add(id);
    }
    notifyListeners();
  }

  void togglePort(int port) {
    if (selectedPorts.contains(port)) {
      if (selectedPorts.length > 1) selectedPorts.remove(port);
    } else {
      selectedPorts.add(port);
    }
    notifyListeners();
  }

  void setParallel(int v) {
    parallel = v.clamp(1, 64);
    notifyListeners();
  }

  void setTimeoutMs(int v) {
    timeoutMs = v.clamp(300, 5000);
    notifyListeners();
  }

  void start() {
    final endpoints = expandEndpoints();
    if (endpoints.isEmpty) return;
    // The native engine caps scans at 4096 endpoints; the Dart fallback
    // must honor the same bound instead of firing tens of thousands of
    // TCP connects (4 ranges x 22 ports would be ~22k sockets).
    if (endpoints.length > NativeBindings.maxWarpEndpoints) {
      _progress = WarpProgress(
        sessionId: 0,
        total: endpoints.length,
        tested: 0,
        succeeded: 0,
        failed: 0,
        isRunning: false,
        isCompleted: false,
        results: const [],
        error:
            'Too many endpoints (${endpoints.length} > ${NativeBindings.maxWarpEndpoints}). Reduce ranges or ports.',
      );
      notifyListeners();
      return;
    }
    stop(silent: true);
    final int runId = ++_runId;
    _cancelFallback = false;

    _progress = const WarpProgress(
      sessionId: 0,
      total: 0,
      tested: 0,
      succeeded: 0,
      failed: 0,
      isRunning: true,
      isCompleted: false,
      results: [],
    );
    notifyListeners();

    if (_bindings.isWarpReady) {
      final useProfile = _useProfileForScan &&
          _profile != null &&
          _bindings.isWarpProfileReady;
      _startNative(endpoints, runId, useProfile: useProfile);
    } else {
      _startFallback(endpoints, runId);
    }
  }

  void _startNative(List<String> endpoints, int runId,
      {bool useProfile = false}) {
    _isUsingNativeOverride = true;
    final csv = endpoints.join(',');
    final p = useProfile ? _profile : null;
    _activeSessionId = p != null
        ? _bindings.startWarpProfileScan(
            csv, parallel, timeoutMs, p.privateKeyBytes, p.publicKeyBytes)
        : _bindings.startWarpScan(csv, parallel, timeoutMs);
    if (_activeSessionId == 0) {
      _startFallback(endpoints, runId);
      return;
    }
    _pollTimer?.cancel();
    int lastTested = -1;
    final accumulated = <WarpResult>[];
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (_activeSessionId == 0 || runId != _runId) {
        timer.cancel();
        return;
      }
      // Incremental deltas: only results appended since the last poll
      // cross FFI, instead of re-serializing up to 4096 rows per tick.
      final jsonStr =
          _bindings.pollWarpSince(_activeSessionId, accumulated.length);
      if (jsonStr == null || jsonStr.isEmpty) return;
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        final deltaResults = (map['newResults'] as List<dynamic>?)
                ?.map((e) => WarpResult.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <WarpResult>[];
        accumulated.addAll(deltaResults);
        final next = WarpProgress(
          sessionId: _activeSessionId,
          total: (map['total'] as num?)?.toInt() ?? 0,
          tested: (map['tested'] as num?)?.toInt() ?? accumulated.length,
          succeeded: (map['succeeded'] as num?)?.toInt() ?? 0,
          failed: (map['failed'] as num?)?.toInt() ?? 0,
          isRunning: (map['isRunning'] as bool?) ?? true,
          isCompleted: (map['isCompleted'] as bool?) ?? false,
          error: map['error'] as String?,
          results: List.of(accumulated),
        );
        // Notify only on progress steps (throttles rebuilds).
        if (next.tested != lastTested ||
            next.isCompleted != _progress.isCompleted) {
          lastTested = next.tested;
          _progress = next;
          notifyListeners();
        } else {
          _progress = next;
        }
        if (next.isCompleted) {
          timer.cancel();
          try {
            _bindings.freeWarp(_activeSessionId);
          } catch (_) {}
          _activeSessionId = 0;
        }
      } catch (_) {}
    });
  }

  // --- Dart fallback: TCP connect per endpoint, chunked ---
  Future<void> _startFallback(List<String> endpoints, int runId) async {
    _isUsingNativeOverride = false;
    final results = <WarpResult>[];
    int tested = 0, ok = 0;
    final chunk = parallel.clamp(1, 64);

    for (int i = 0; i < endpoints.length; i += chunk) {
      if (_cancelFallback || runId != _runId) break;
      final slice =
          endpoints.sublist(i, (i + chunk).clamp(0, endpoints.length));
      final chunkResults =
          await Future.wait(slice.map((e) => _tcpProbeFallback(e)));
      if (_cancelFallback || runId != _runId) break;
      for (final r in chunkResults) {
        results.add(r);
        tested++;
        if (r.success) ok++;
      }
      _progress = WarpProgress(
        sessionId: 0,
        total: endpoints.length,
        tested: tested,
        succeeded: ok,
        failed: tested - ok,
        isRunning: true,
        isCompleted: false,
        results: List.of(results),
      );
      notifyListeners();
    }

    if (!_cancelFallback && runId == _runId) {
      _progress = WarpProgress(
        sessionId: 0,
        total: endpoints.length,
        tested: tested,
        succeeded: ok,
        failed: tested - ok,
        isRunning: false,
        isCompleted: true,
        results: List.of(results),
      );
      notifyListeners();
    }
  }

  Future<WarpResult> _tcpProbeFallback(String endpoint) async {
    final sep = endpoint.lastIndexOf(':');
    final ip = endpoint.substring(0, sep);
    final port = int.tryParse(endpoint.substring(sep + 1)) ?? 0;
    final sw = Stopwatch()..start();
    try {
      final sock = await _connectWithTimeout(ip, port, timeoutMs);
      sw.stop();
      sock.destroy();
      return WarpResult(
        ip: ip,
        port: port,
        endpoint: endpoint,
        rttMs: sw.elapsedMicroseconds / 1000.0,
        success: true,
        note: 'via TCP fallback (Dart)',
      );
    } catch (_) {
      return WarpResult(
        ip: ip,
        port: port,
        endpoint: endpoint,
        rttMs: -1.0,
        success: false,
        note: 'timeout',
      );
    }
  }

  Future<Socket> _connectWithTimeout(String ip, int port, int ms) {
    return ws.warpSocketConnectImpl(ip, port, ms);
  }

  void stop({bool silent = false}) {
    _pollTimer?.cancel();
    _pollTimer = null;
    _runId++;
    _cancelFallback = true;
    final sid = _activeSessionId;
    _activeSessionId = 0;
    if (sid != 0) {
      try {
        _bindings.stopWarp(sid);
      } catch (_) {}
      try {
        _bindings.freeWarp(sid);
      } catch (_) {}
    }
    if (_progress.isRunning && !silent) {
      _progress = WarpProgress(
        sessionId: _progress.sessionId,
        total: _progress.total,
        tested: _progress.tested,
        succeeded: _progress.succeeded,
        failed: _progress.failed,
        isRunning: false,
        isCompleted: true,
        results: _progress.results,
      );
      notifyListeners();
    }
  }

  /// Parses and installs a WireGuard profile from raw `.conf` text.
  /// Returns true on success; [profileError] carries the reason otherwise.
  bool setProfile(String raw) {
    final parsed = WarpProfile.parse(raw);
    final profile = parsed.profile;
    if (profile == null) {
      _profileError = parsed.error ?? 'Invalid profile.';
      notifyListeners();
      return false;
    }
    _profile = profile;
    _profileError = null;
    _profileValidation = null;
    // Invalidate any in-flight validation for the previous profile so its
    // result can never be attributed to this one.
    _validationRunId++;
    _validatingProfile = false;
    notifyListeners();
    return true;
  }

  void clearProfile() {
    if (_profile == null && _profileError == null) return;
    _profile = null;
    _profileError = null;
    _profileValidation = null;
    _validationRunId++;
    _validatingProfile = false;
    notifyListeners();
  }

  void setUseProfileForScan(bool value) {
    if (_useProfileForScan == value) return;
    _useProfileForScan = value;
    notifyListeners();
  }

  /// Proves the imported identity against the profile's own endpoint.
  ///
  /// Resolves the endpoint hostname in Dart (FFI takes IPs only), then asks
  /// the engine for a handshake signed by the profile's private key. Only a
  /// validated 92-byte response counts as confirmation; an open TCP port is
  /// reported separately and must never be treated as profile acceptance.
  Future<WarpProfileValidation> validateProfile() async {
    final p = _profile;
    if (p == null) {
      return const WarpProfileValidation(
        status: WarpProfileValidationStatus.failed,
        endpoint: '',
        detail: 'No profile loaded.',
      );
    }
    if (!_bindings.isWarpProfileReady) {
      final v = WarpProfileValidation(
        status: WarpProfileValidationStatus.unsupported,
        endpoint: p.displayEndpoint,
        detail:
            'The loaded native engine does not expose profile handshakes; rebuild netstudio_engine.',
      );
      _profileValidation = v;
      notifyListeners();
      return v;
    }
    if (_validatingProfile) {
      return _profileValidation ??
          WarpProfileValidation(
            status: WarpProfileValidationStatus.failed,
            endpoint: p.displayEndpoint,
            detail: 'Validation already running.',
          );
    }

    final runId = ++_validationRunId;
    _validatingProfile = true;
    _profileValidation = null;
    notifyListeners();

    int sessionId = 0;
    WarpProfileValidation result;
    try {
      final addresses = await InternetAddress.lookup(p.endpointHost)
          .timeout(const Duration(seconds: 6));
      final seen = <String>{};
      final ips = addresses.map((a) => a.address).where(seen.add).toList()
        ..sort((a, b) {
          final a6 = a.contains(':') ? 1 : 0;
          final b6 = b.contains(':') ? 1 : 0;
          return a6.compareTo(b6);
        });
      if (ips.isEmpty) {
        result = WarpProfileValidation(
          status: WarpProfileValidationStatus.failed,
          endpoint: p.displayEndpoint,
          detail: 'Endpoint hostname did not resolve.',
        );
      } else {
        final csv = ips.take(4).map((ip) {
          return ip.contains(':')
              ? '[$ip]:${p.endpointPort}'
              : '$ip:${p.endpointPort}';
        }).join(',');
        sessionId = _bindings.startWarpProfileScan(
            csv, 4, 5000, p.privateKeyBytes, p.publicKeyBytes);
        if (sessionId == 0) {
          result = WarpProfileValidation(
            status: WarpProfileValidationStatus.failed,
            endpoint: p.displayEndpoint,
            detail: 'The engine refused to start the validation probe.',
          );
        } else {
          final results = <WarpResult>[];
          for (int tick = 0; tick < 75; tick++) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            if (runId != _validationRunId) break;
            final json = _bindings.pollWarpSince(sessionId, results.length);
            if (json != null && json.isNotEmpty) {
              try {
                final map = jsonDecode(json) as Map<String, dynamic>;
                final fresh = (map['newResults'] as List<dynamic>?)
                        ?.map((e) =>
                            WarpResult.fromJson(e as Map<String, dynamic>))
                        .toList() ??
                    const <WarpResult>[];
                results.addAll(fresh);
                if ((map['isCompleted'] as bool?) ?? false) break;
              } catch (_) {}
            }
          }
          result = _judgeProfileValidation(p, results);
        }
      }
    } catch (e) {
      result = WarpProfileValidation(
        status: WarpProfileValidationStatus.failed,
        endpoint: p.displayEndpoint,
        detail: 'Validation failed: $e',
      );
    } finally {
      if (sessionId != 0) {
        try {
          _bindings.freeWarp(sessionId);
        } catch (_) {}
      }
      // Only the current run owns the busy flag: an invalidated (profile
      // replaced/cleared) run must not clear a newer validation's spinner.
      if (runId == _validationRunId) _validatingProfile = false;
    }

    if (runId == _validationRunId) {
      _profileValidation = result;
      if (!_disposed) notifyListeners();
    }
    return result;
  }

  WarpProfileValidation _judgeProfileValidation(
      WarpProfile p, List<WarpResult> results) {
    final confirmed = results.where((r) => r.success && r.handshake).toList()
      ..sort((a, b) => a.rttMs.compareTo(b.rttMs));
    if (confirmed.isNotEmpty) {
      return WarpProfileValidation(
        status: WarpProfileValidationStatus.confirmed,
        endpoint: confirmed.first.endpoint,
        rttMs: confirmed.first.rttMs,
        detail: 'WireGuard handshake accepted the imported identity.',
      );
    }
    final reachable = results.where((r) => r.success).toList()
      ..sort((a, b) => a.rttMs.compareTo(b.rttMs));
    if (reachable.isNotEmpty) {
      return WarpProfileValidation(
        status: WarpProfileValidationStatus.reachableOnly,
        endpoint: reachable.first.endpoint,
        rttMs: reachable.first.rttMs,
        detail:
            'Host reachable via TCP, but no WireGuard handshake reply arrived — identity not confirmed.',
      );
    }
    final reason = results
        .map((r) => r.note)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    return WarpProfileValidation(
      status: WarpProfileValidationStatus.failed,
      endpoint: p.displayEndpoint,
      detail: reason.isEmpty
          ? 'No response from the profile endpoint.'
          : reason.first,
    );
  }

  /// Builds PingTarget entries (TCP) for the top-N ranked endpoints so the
  /// user can monitor them in the Ping Matrix tab. Caller assigns IDs.
  List<PingTarget> buildPingTargets({int count = 5, int idStart = 1000}) {
    final ranked = _progress.ranked.take(count).toList();
    final out = <PingTarget>[];
    for (int i = 0; i < ranked.length; i++) {
      final r = ranked[i];
      out.add(PingTarget(
        id: idStart + i,
        name: 'Warp #${i + 1} (${r.ip})',
        host: r.ip,
        port: r.port,
        protocol: NetworkProtocol.tcp,
        intervalMs: 1200,
        timeoutMs: 2000,
      ));
    }
    return out;
  }

  /// WireGuard-style config snippet for the best endpoint.
  String buildConfigSnippet({int index = 0}) {
    final ranked = _progress.ranked;
    if (ranked.isEmpty) return '';
    final r = ranked[index.clamp(0, ranked.length - 1)];
    return 'Endpoint = ${r.endpoint}';
  }

  @override
  void dispose() {
    _disposed = true;
    _validationRunId++;
    stop(silent: true);
    super.dispose();
  }
}

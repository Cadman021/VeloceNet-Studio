import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'native_library.dart';

// Engine handles are opaque numeric ids owned by the Rust side (0 = invalid),
// not raw pointers: a stale or double free from Dart can never dereference
// freed memory.
typedef NetstudioEngineNewNative = Uint32 Function();
typedef NetstudioEngineNewDart = int Function();

typedef NetstudioEngineFreeNative = Void Function(Uint32);
typedef NetstudioEngineFreeDart = void Function(int);

typedef NetstudioAddTargetNative = Bool Function(
  Uint32 engine,
  Uint32 id,
  Pointer<Utf8> name,
  Pointer<Utf8> host,
  Uint16 port,
  Uint32 protocol,
  Uint64 intervalMs,
  Uint64 timeoutMs,
  Pointer<Utf8> path,
);
typedef NetstudioAddTargetDart = bool Function(
  int engine,
  int id,
  Pointer<Utf8> name,
  Pointer<Utf8> host,
  int port,
  int protocol,
  int intervalMs,
  int timeoutMs,
  Pointer<Utf8> path,
);

typedef NetstudioRemoveTargetNative = Bool Function(Uint32, Uint32);
typedef NetstudioRemoveTargetDart = bool Function(int, int);

typedef NetstudioStartNative = Bool Function(Uint32);
typedef NetstudioStartDart = bool Function(int);

typedef NetstudioStopNative = Bool Function(Uint32);
typedef NetstudioStopDart = bool Function(int);

typedef NetstudioIsRunningNative = Bool Function(Uint32);
typedef NetstudioIsRunningDart = bool Function(int);

typedef NetstudioGetMetricsJsonNative = Pointer<Utf8> Function(Uint32);
typedef NetstudioGetMetricsJsonDart = Pointer<Utf8> Function(int);

typedef NetstudioFreeStringNative = Void Function(Pointer<Utf8>);
typedef NetstudioFreeStringDart = void Function(Pointer<Utf8>);

typedef NetstudioTracerouteStartNative = Uint32 Function(
  Pointer<Utf8> host,
  Uint8 maxHops,
  Uint32 timeoutMs,
);
typedef NetstudioTracerouteStartDart = int Function(
  Pointer<Utf8> host,
  int maxHops,
  int timeoutMs,
);

typedef NetstudioTraceroutePollNative = Pointer<Utf8> Function(
    Uint32 sessionId);
typedef NetstudioTraceroutePollDart = Pointer<Utf8> Function(int sessionId);

typedef NetstudioTracerouteStopNative = Bool Function(Uint32 sessionId);
typedef NetstudioTracerouteStopDart = bool Function(int sessionId);

typedef NetstudioTracerouteFreeNative = Void Function(Uint32 sessionId);
typedef NetstudioTracerouteFreeDart = void Function(int sessionId);

typedef NetstudioBandwidthStartNative = Bool Function(Uint32 intervalMs);
typedef NetstudioBandwidthStartDart = bool Function(int intervalMs);

typedef NetstudioBandwidthStopNative = Bool Function();
typedef NetstudioBandwidthStopDart = bool Function();

typedef NetstudioBandwidthPollNative = Pointer<Utf8> Function();
typedef NetstudioBandwidthPollDart = Pointer<Utf8> Function();

typedef NetstudioBandwidthIsRunningNative = Bool Function();
typedef NetstudioBandwidthIsRunningDart = bool Function();

typedef NetstudioSetAlertThresholdsNative = Void Function(
    Uint32 offlineAfter, Uint32 recoverAfter);
typedef NetstudioSetAlertThresholdsDart = void Function(
    int offlineAfter, int recoverAfter);

typedef NetstudioWarpStartNative = Uint32 Function(
  Pointer<Utf8> endpointsCsv,
  Uint32 parallel,
  Uint32 timeoutMs,
);
typedef NetstudioWarpStartDart = int Function(
  Pointer<Utf8> endpointsCsv,
  int parallel,
  int timeoutMs,
);

typedef NetstudioWarpPollSinceNative = Pointer<Utf8> Function(
    Uint32 sessionId, Uint32 sinceIndex);
typedef NetstudioWarpPollSinceDart = Pointer<Utf8> Function(
    int sessionId, int sinceIndex);

typedef NetstudioWarpStopNative = Bool Function(Uint32 sessionId);
typedef NetstudioWarpStopDart = bool Function(int sessionId);

typedef NetstudioWarpFreeNative = Void Function(Uint32 sessionId);
typedef NetstudioWarpFreeDart = void Function(int sessionId);

class NativeBindings {
  static final NativeBindings _instance = NativeBindings._internal();
  factory NativeBindings() => _instance;

  final DynamicLibrary? _lib;

  NetstudioEngineNewDart? _engineNew;
  NetstudioEngineFreeDart? _engineFree;
  NetstudioSetAlertThresholdsDart? _setAlertThresholds;
  NetstudioAddTargetDart? _addTarget;
  NetstudioRemoveTargetDart? _removeTarget;
  NetstudioStartDart? _start;
  NetstudioStopDart? _stop;
  NetstudioIsRunningDart? _isRunning;
  NetstudioGetMetricsJsonDart? _getMetricsJson;
  NetstudioFreeStringDart? _freeString;

  NetstudioTracerouteStartDart? _tracerouteStart;
  NetstudioTraceroutePollDart? _traceroutePoll;
  NetstudioTracerouteStopDart? _tracerouteStop;
  NetstudioTracerouteFreeDart? _tracerouteFree;

  NetstudioBandwidthStartDart? _bandwidthStart;
  NetstudioBandwidthStopDart? _bandwidthStop;
  NetstudioBandwidthPollDart? _bandwidthPoll;
  NetstudioBandwidthIsRunningDart? _bandwidthIsRunning;

  NetstudioWarpStartDart? _warpStart;
  NetstudioWarpPollSinceDart? _warpPoll;
  NetstudioWarpStopDart? _warpStop;
  NetstudioWarpFreeDart? _warpFree;

  NativeBindings._internal() : _lib = NativeLibrary.instance {
    final lib = _lib;
    if (lib != null) {
      try {
        _engineNew = lib.lookupFunction<NetstudioEngineNewNative,
            NetstudioEngineNewDart>('netstudio_engine_new');
      } catch (_) {}
      try {
        _engineFree = lib.lookupFunction<NetstudioEngineFreeNative,
            NetstudioEngineFreeDart>('netstudio_engine_free');
      } catch (_) {}
      try {
        _setAlertThresholds = lib.lookupFunction<
            NetstudioSetAlertThresholdsNative,
            NetstudioSetAlertThresholdsDart>('netstudio_set_alert_thresholds');
      } catch (_) {}
      try {
        _addTarget = lib.lookupFunction<NetstudioAddTargetNative,
            NetstudioAddTargetDart>('netstudio_add_target');
      } catch (_) {}
      try {
        _removeTarget = lib.lookupFunction<NetstudioRemoveTargetNative,
            NetstudioRemoveTargetDart>('netstudio_remove_target');
      } catch (_) {}
      try {
        _start = lib.lookupFunction<NetstudioStartNative, NetstudioStartDart>(
            'netstudio_start');
      } catch (_) {}
      try {
        _stop = lib.lookupFunction<NetstudioStopNative, NetstudioStopDart>(
            'netstudio_stop');
      } catch (_) {}
      try {
        _isRunning = lib.lookupFunction<NetstudioIsRunningNative,
            NetstudioIsRunningDart>('netstudio_is_running');
      } catch (_) {}
      try {
        _getMetricsJson = lib.lookupFunction<NetstudioGetMetricsJsonNative,
            NetstudioGetMetricsJsonDart>('netstudio_get_metrics_json');
      } catch (_) {}
      try {
        _freeString = lib.lookupFunction<NetstudioFreeStringNative,
            NetstudioFreeStringDart>('netstudio_free_string');
      } catch (_) {}
      try {
        _tracerouteStart = lib.lookupFunction<NetstudioTracerouteStartNative,
            NetstudioTracerouteStartDart>('netstudio_traceroute_start');
      } catch (_) {}
      try {
        _traceroutePoll = lib.lookupFunction<NetstudioTraceroutePollNative,
            NetstudioTraceroutePollDart>('netstudio_traceroute_poll');
      } catch (_) {}
      try {
        _tracerouteStop = lib.lookupFunction<NetstudioTracerouteStopNative,
            NetstudioTracerouteStopDart>('netstudio_traceroute_stop');
      } catch (_) {}
      try {
        _tracerouteFree = lib.lookupFunction<NetstudioTracerouteFreeNative,
            NetstudioTracerouteFreeDart>('netstudio_traceroute_free');
      } catch (_) {}

      try {
        _bandwidthStart = lib.lookupFunction<NetstudioBandwidthStartNative,
            NetstudioBandwidthStartDart>('netstudio_bandwidth_start');
      } catch (_) {}
      try {
        _bandwidthStop = lib.lookupFunction<NetstudioBandwidthStopNative,
            NetstudioBandwidthStopDart>('netstudio_bandwidth_stop');
      } catch (_) {}
      try {
        _bandwidthPoll = lib.lookupFunction<NetstudioBandwidthPollNative,
            NetstudioBandwidthPollDart>('netstudio_bandwidth_poll');
      } catch (_) {}
      try {
        _bandwidthIsRunning = lib.lookupFunction<
            NetstudioBandwidthIsRunningNative,
            NetstudioBandwidthIsRunningDart>('netstudio_bandwidth_is_running');
      } catch (_) {}

      try {
        _warpStart = lib.lookupFunction<NetstudioWarpStartNative,
            NetstudioWarpStartDart>('netstudio_warp_start');
      } catch (_) {}
      try {
        _warpPoll = lib.lookupFunction<NetstudioWarpPollSinceNative,
            NetstudioWarpPollSinceDart>('netstudio_warp_poll_since');
      } catch (_) {}
      try {
        _warpStop =
            lib.lookupFunction<NetstudioWarpStopNative, NetstudioWarpStopDart>(
                'netstudio_warp_stop');
      } catch (_) {}
      try {
        _warpFree =
            lib.lookupFunction<NetstudioWarpFreeNative, NetstudioWarpFreeDart>(
                'netstudio_warp_free');
      } catch (_) {}
    }
  }

  bool get isReady => _lib != null && _engineNew != null && _engineFree != null;
  bool get isTracerouteReady =>
      _lib != null &&
      _tracerouteStart != null &&
      _traceroutePoll != null &&
      _tracerouteStop != null &&
      _tracerouteFree != null;
  bool get isBandwidthReady =>
      _lib != null &&
      _bandwidthStart != null &&
      _bandwidthPoll != null &&
      _bandwidthStop != null;

  static bool isValidHost(String host) {
    if (host.isEmpty || host.length > 253) return false;
    // Allow letters, digits, dots, hyphens, colons (IPv6), brackets.
    return RegExp(r'^[A-Za-z0-9.\-:\[\]_]+$').hasMatch(host);
  }

  static bool isValidPort(int port) => port >= 1 && port <= 65535;
  static bool isValidProtocol(int p) => p >= 0 && p <= 3;
  static bool isValidHttpPath(String path) =>
      path.isEmpty ||
      (path.length <= 256 &&
          path.startsWith('/') &&
          !RegExp(r'[\x00-\x1F\x7F]').hasMatch(path));
  static int clampInterval(int v) => v.clamp(200, 60000);
  static int clampTimeout(int v) => v.clamp(100, 10000);

  int createEngine() => _engineNew?.call() ?? 0;
  void freeEngine(int engine) {
    if (engine != 0) {
      _engineFree?.call(engine);
    }
  }

  /// Process-wide alert thresholds (clamped 1..20 engine-side). No-op when
  /// the native library is absent (Dart fallback mirrors them separately).
  void setAlertThresholds(int offlineAfter, int recoverAfter) {
    _setAlertThresholds?.call(
      offlineAfter.clamp(1, 20),
      recoverAfter.clamp(1, 20),
    );
  }

  bool addTarget(
    int engine,
    int id,
    String name,
    String host,
    int port,
    int protocol,
    int intervalMs,
    int timeoutMs,
    String httpPath,
  ) {
    if (_addTarget == null) {
      return false;
    }
    if (!isValidHost(host) ||
        !isValidPort(port) ||
        !isValidProtocol(protocol) ||
        !isValidHttpPath(httpPath)) {
      return false;
    }
    final safeName =
        name.isEmpty ? host : name.substring(0, name.length.clamp(0, 128));
    final namePtr = safeName.toNativeUtf8();
    final hostPtr = host.toNativeUtf8();
    final pathPtr = httpPath.toNativeUtf8();
    try {
      return _addTarget!(
        engine,
        id,
        namePtr,
        hostPtr,
        port,
        protocol,
        clampInterval(intervalMs),
        clampTimeout(timeoutMs),
        pathPtr,
      );
    } finally {
      calloc.free(namePtr);
      calloc.free(hostPtr);
      calloc.free(pathPtr);
    }
  }

  bool removeTarget(int engine, int id) =>
      _removeTarget?.call(engine, id) ?? false;
  bool startEngine(int engine) => _start?.call(engine) ?? false;
  bool stopEngine(int engine) => _stop?.call(engine) ?? false;
  bool isEngineRunning(int engine) => _isRunning?.call(engine) ?? false;

  String? getMetricsJson(int engine) {
    if (_getMetricsJson == null || _freeString == null) return null;
    final strPtr = _getMetricsJson!(engine);
    if (strPtr == nullptr) return null;
    try {
      return strPtr.toDartString();
    } finally {
      _freeString!(strPtr);
    }
  }

  int startTraceroute(String host, int maxHops, int timeoutMs) {
    if (_tracerouteStart == null) return 0;
    if (!isValidHost(host)) return 0;
    final hostPtr = host.toNativeUtf8();
    try {
      return _tracerouteStart!(
          hostPtr, maxHops.clamp(1, 64), clampTimeout(timeoutMs));
    } finally {
      calloc.free(hostPtr);
    }
  }

  String? pollTraceroute(int sessionId) {
    if (_traceroutePoll == null || _freeString == null || sessionId == 0) {
      return null;
    }
    final strPtr = _traceroutePoll!(sessionId);
    if (strPtr == nullptr) return null;
    try {
      return strPtr.toDartString();
    } finally {
      _freeString!(strPtr);
    }
  }

  bool stopTraceroute(int sessionId) {
    if (_tracerouteStop == null || sessionId == 0) return false;
    return _tracerouteStop!(sessionId);
  }

  void freeTraceroute(int sessionId) {
    if (_tracerouteFree == null || sessionId == 0) return;
    _tracerouteFree!(sessionId);
  }

  bool startBandwidth(int intervalMs) {
    if (_bandwidthStart == null) return false;
    return _bandwidthStart!(intervalMs);
  }

  bool stopBandwidth() {
    if (_bandwidthStop == null) return false;
    return _bandwidthStop!();
  }

  String? pollBandwidth() {
    if (_bandwidthPoll == null || _freeString == null) return null;
    final strPtr = _bandwidthPoll!();
    if (strPtr == nullptr) return null;
    try {
      return strPtr.toDartString();
    } finally {
      _freeString!(strPtr);
    }
  }

  bool isBandwidthRunning() {
    if (_bandwidthIsRunning == null) return false;
    return _bandwidthIsRunning!();
  }

  bool get isWarpReady =>
      _lib != null && _warpStart != null && _warpPoll != null;

  /// Max endpoints per scan to avoid multi-MB CSV / OOM in native code.
  static const int maxWarpEndpoints = 4096;

  int startWarpScan(String endpointsCsv, int parallel, int timeoutMs) {
    if (_warpStart == null) return 0;
    if (endpointsCsv.isEmpty || endpointsCsv.length > 256 * 1024) return 0;
    final parts = endpointsCsv.split(',');
    if (parts.length > maxWarpEndpoints) return 0;
    for (final p in parts) {
      final item = p.trim();
      if (item.isEmpty) continue;
      final idx = item.lastIndexOf(':');
      if (idx <= 0) return 0;
      final ip = item.substring(0, idx).trim();
      final port = int.tryParse(item.substring(idx + 1).trim());
      if (!isValidHost(ip) || port == null || !isValidPort(port)) return 0;
    }
    final csvPtr = endpointsCsv.toNativeUtf8();
    try {
      return _warpStart!(
          csvPtr, parallel.clamp(1, 64), clampTimeout(timeoutMs));
    } finally {
      calloc.free(csvPtr);
    }
  }

  /// Incremental warp poll: returns counters plus only the results
  /// appended since [sinceIndex] (see `WarpDelta` on the Rust side).
  String? pollWarpSince(int sessionId, int sinceIndex) {
    if (_warpPoll == null || _freeString == null || sessionId == 0) return null;
    final strPtr = _warpPoll!(sessionId, sinceIndex);
    if (strPtr == nullptr) return null;
    try {
      return strPtr.toDartString();
    } finally {
      _freeString!(strPtr);
    }
  }

  bool stopWarp(int sessionId) {
    if (_warpStop == null || sessionId == 0) return false;
    return _warpStop!(sessionId);
  }

  void freeWarp(int sessionId) {
    if (_warpFree == null || sessionId == 0) return;
    _warpFree!(sessionId);
  }
}

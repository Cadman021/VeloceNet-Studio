import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'native_library.dart';

// Native function C typedefs
typedef NetstudioEngineNewNative = Pointer<Void> Function();
typedef NetstudioEngineNewDart = Pointer<Void> Function();

typedef NetstudioEngineFreeNative = Void Function(Pointer<Void>);
typedef NetstudioEngineFreeDart = void Function(Pointer<Void>);

typedef NetstudioAddTargetNative = Bool Function(
  Pointer<Void> engine,
  Uint32 id,
  Pointer<Utf8> name,
  Pointer<Utf8> host,
  Uint16 port,
  Uint32 protocol,
  Uint64 intervalMs,
  Uint64 timeoutMs,
);
typedef NetstudioAddTargetDart = bool Function(
  Pointer<Void> engine,
  int id,
  Pointer<Utf8> name,
  Pointer<Utf8> host,
  int port,
  int protocol,
  int intervalMs,
  int timeoutMs,
);

typedef NetstudioRemoveTargetNative = Bool Function(Pointer<Void>, Uint32);
typedef NetstudioRemoveTargetDart = bool Function(Pointer<Void>, int);

typedef NetstudioStartNative = Bool Function(Pointer<Void>);
typedef NetstudioStartDart = bool Function(Pointer<Void>);

typedef NetstudioStopNative = Bool Function(Pointer<Void>);
typedef NetstudioStopDart = bool Function(Pointer<Void>);

typedef NetstudioIsRunningNative = Bool Function(Pointer<Void>);
typedef NetstudioIsRunningDart = bool Function(Pointer<Void>);

typedef NetstudioGetMetricsJsonNative = Pointer<Utf8> Function(Pointer<Void>);
typedef NetstudioGetMetricsJsonDart = Pointer<Utf8> Function(Pointer<Void>);

typedef NetstudioFreeStringNative = Void Function(Pointer<Utf8>);
typedef NetstudioFreeStringDart = void Function(Pointer<Utf8>);

typedef NetstudioQuickPingNative = Double Function(
  Pointer<Utf8> host,
  Uint16 port,
  Uint32 protocol,
  Uint32 timeoutMs,
);
typedef NetstudioQuickPingDart = double Function(
  Pointer<Utf8> host,
  int port,
  int protocol,
  int timeoutMs,
);

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

typedef NetstudioTraceroutePollNative = Pointer<Utf8> Function(Uint32 sessionId);
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

typedef NetstudioWarpPollNative = Pointer<Utf8> Function(Uint32 sessionId);
typedef NetstudioWarpPollDart = Pointer<Utf8> Function(int sessionId);

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
  NetstudioAddTargetDart? _addTarget;
  NetstudioRemoveTargetDart? _removeTarget;
  NetstudioStartDart? _start;
  NetstudioStopDart? _stop;
  NetstudioIsRunningDart? _isRunning;
  NetstudioGetMetricsJsonDart? _getMetricsJson;
  NetstudioFreeStringDart? _freeString;
  NetstudioQuickPingDart? _quickPing;

  NetstudioTracerouteStartDart? _tracerouteStart;
  NetstudioTraceroutePollDart? _traceroutePoll;
  NetstudioTracerouteStopDart? _tracerouteStop;
  NetstudioTracerouteFreeDart? _tracerouteFree;

  NetstudioBandwidthStartDart? _bandwidthStart;
  NetstudioBandwidthStopDart? _bandwidthStop;
  NetstudioBandwidthPollDart? _bandwidthPoll;
  NetstudioBandwidthIsRunningDart? _bandwidthIsRunning;

  NetstudioWarpStartDart? _warpStart;
  NetstudioWarpPollDart? _warpPoll;
  NetstudioWarpStopDart? _warpStop;
  NetstudioWarpFreeDart? _warpFree;

  NativeBindings._internal() : _lib = NativeLibrary.instance {
    final lib = _lib;
    if (lib != null) {
      try {
        _engineNew = lib.lookupFunction<NetstudioEngineNewNative, NetstudioEngineNewDart>('netstudio_engine_new');
      } catch (_) {}
      try {
        _engineFree = lib.lookupFunction<NetstudioEngineFreeNative, NetstudioEngineFreeDart>('netstudio_engine_free');
      } catch (_) {}
      try {
        _addTarget = lib.lookupFunction<NetstudioAddTargetNative, NetstudioAddTargetDart>('netstudio_add_target');
      } catch (_) {}
      try {
        _removeTarget = lib.lookupFunction<NetstudioRemoveTargetNative, NetstudioRemoveTargetDart>('netstudio_remove_target');
      } catch (_) {}
      try {
        _start = lib.lookupFunction<NetstudioStartNative, NetstudioStartDart>('netstudio_start');
      } catch (_) {}
      try {
        _stop = lib.lookupFunction<NetstudioStopNative, NetstudioStopDart>('netstudio_stop');
      } catch (_) {}
      try {
        _isRunning = lib.lookupFunction<NetstudioIsRunningNative, NetstudioIsRunningDart>('netstudio_is_running');
      } catch (_) {}
      try {
        _getMetricsJson = lib.lookupFunction<NetstudioGetMetricsJsonNative, NetstudioGetMetricsJsonDart>('netstudio_get_metrics_json');
      } catch (_) {}
      try {
        _freeString = lib.lookupFunction<NetstudioFreeStringNative, NetstudioFreeStringDart>('netstudio_free_string');
      } catch (_) {}
      try {
        _quickPing = lib.lookupFunction<NetstudioQuickPingNative, NetstudioQuickPingDart>('netstudio_quick_ping');
      } catch (_) {}

      try {
        _tracerouteStart = lib.lookupFunction<NetstudioTracerouteStartNative, NetstudioTracerouteStartDart>('netstudio_traceroute_start');
      } catch (_) {}
      try {
        _traceroutePoll = lib.lookupFunction<NetstudioTraceroutePollNative, NetstudioTraceroutePollDart>('netstudio_traceroute_poll');
      } catch (_) {}
      try {
        _tracerouteStop = lib.lookupFunction<NetstudioTracerouteStopNative, NetstudioTracerouteStopDart>('netstudio_traceroute_stop');
      } catch (_) {}
      try {
        _tracerouteFree = lib.lookupFunction<NetstudioTracerouteFreeNative, NetstudioTracerouteFreeDart>('netstudio_traceroute_free');
      } catch (_) {}

      try {
        _bandwidthStart = lib.lookupFunction<NetstudioBandwidthStartNative, NetstudioBandwidthStartDart>('netstudio_bandwidth_start');
      } catch (_) {}
      try {
        _bandwidthStop = lib.lookupFunction<NetstudioBandwidthStopNative, NetstudioBandwidthStopDart>('netstudio_bandwidth_stop');
      } catch (_) {}
      try {
        _bandwidthPoll = lib.lookupFunction<NetstudioBandwidthPollNative, NetstudioBandwidthPollDart>('netstudio_bandwidth_poll');
      } catch (_) {}
      try {
        _bandwidthIsRunning = lib.lookupFunction<NetstudioBandwidthIsRunningNative, NetstudioBandwidthIsRunningDart>('netstudio_bandwidth_is_running');
      } catch (_) {}

      try {
        _warpStart = lib.lookupFunction<NetstudioWarpStartNative, NetstudioWarpStartDart>('netstudio_warp_start');
      } catch (_) {}
      try {
        _warpPoll = lib.lookupFunction<NetstudioWarpPollNative, NetstudioWarpPollDart>('netstudio_warp_poll');
      } catch (_) {}
      try {
        _warpStop = lib.lookupFunction<NetstudioWarpStopNative, NetstudioWarpStopDart>('netstudio_warp_stop');
      } catch (_) {}
      try {
        _warpFree = lib.lookupFunction<NetstudioWarpFreeNative, NetstudioWarpFreeDart>('netstudio_warp_free');
      } catch (_) {}
    }
  }

  bool get isReady => _lib != null && _engineNew != null && _engineFree != null;
  bool get isTracerouteReady =>
      _lib != null && _tracerouteStart != null && _traceroutePoll != null && _tracerouteStop != null && _tracerouteFree != null;
  bool get isBandwidthReady =>
      _lib != null && _bandwidthStart != null && _bandwidthPoll != null && _bandwidthStop != null;

  static bool isValidHost(String host) {
    if (host.isEmpty || host.length > 253) return false;
    // Allow letters, digits, dots, hyphens, colons (IPv6), brackets.
    return RegExp(r'^[A-Za-z0-9.\-:\[\]_]+$').hasMatch(host);
  }

  static bool isValidPort(int port) => port >= 1 && port <= 65535;
  static bool isValidProtocol(int p) => p == 0 || p == 1;
  static int clampInterval(int v) => v.clamp(200, 60000);
  static int clampTimeout(int v) => v.clamp(100, 10000);

  Pointer<Void>? createEngine() => _engineNew?.call();
  void freeEngine(Pointer<Void> engine) => _engineFree?.call(engine);

  bool addTarget(
    Pointer<Void> engine,
    int id,
    String name,
    String host,
    int port,
    int protocol,
    int intervalMs,
    int timeoutMs,
  ) {
    if (_addTarget == null) return false;
    if (!isValidHost(host) || !isValidPort(port) || !isValidProtocol(protocol)) return false;
    final safeName = name.isEmpty ? host : name.substring(0, name.length.clamp(0, 128));
    final namePtr = safeName.toNativeUtf8();
    final hostPtr = host.toNativeUtf8();
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
      );
    } finally {
      calloc.free(namePtr);
      calloc.free(hostPtr);
    }
  }

  bool removeTarget(Pointer<Void> engine, int id) => _removeTarget?.call(engine, id) ?? false;
  bool startEngine(Pointer<Void> engine) => _start?.call(engine) ?? false;
  bool stopEngine(Pointer<Void> engine) => _stop?.call(engine) ?? false;
  bool isEngineRunning(Pointer<Void> engine) => _isRunning?.call(engine) ?? false;

  String? getMetricsJson(Pointer<Void> engine) {
    if (_getMetricsJson == null || _freeString == null) return null;
    final strPtr = _getMetricsJson!(engine);
    if (strPtr == nullptr) return null;
    try {
      return strPtr.toDartString();
    } finally {
      _freeString!(strPtr);
    }
  }

  double quickPing(String host, int port, int protocol, int timeoutMs) {
    if (_quickPing == null) return -1.0;
    if (!isValidHost(host) || !isValidPort(port) || !isValidProtocol(protocol)) return -1.0;
    final hostPtr = host.toNativeUtf8();
    try {
      return _quickPing!(hostPtr, port, protocol, clampTimeout(timeoutMs));
    } finally {
      calloc.free(hostPtr);
    }
  }

  int startTraceroute(String host, int maxHops, int timeoutMs) {
    if (_tracerouteStart == null) return 0;
    if (!isValidHost(host)) return 0;
    final hostPtr = host.toNativeUtf8();
    try {
      return _tracerouteStart!(hostPtr, maxHops.clamp(1, 64), clampTimeout(timeoutMs));
    } finally {
      calloc.free(hostPtr);
    }
  }

  String? pollTraceroute(int sessionId) {
    if (_traceroutePoll == null || _freeString == null || sessionId == 0) return null;
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

  bool get isWarpReady => _lib != null && _warpStart != null && _warpPoll != null;

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
      return _warpStart!(csvPtr, parallel.clamp(1, 64), clampTimeout(timeoutMs));
    } finally {
      calloc.free(csvPtr);
    }
  }

  String? pollWarp(int sessionId) {
    if (_warpPoll == null || _freeString == null || sessionId == 0) return null;
    final strPtr = _warpPoll!(sessionId);
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

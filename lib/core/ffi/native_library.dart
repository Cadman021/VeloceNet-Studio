import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

class NativeLibrary {
  static DynamicLibrary? _instance;
  static bool _isLoaded = false;
  static String? _loadedPath;

  static bool get isAvailable => _instance != null;
  static String? get loadedPath => _loadedPath;

  static DynamicLibrary? get instance {
    if (_isLoaded) return _instance;
    _instance = _loadLibrary();
    _isLoaded = true;
    return _instance;
  }

  /// Secure load: in release builds, only from an absolute path anchored
  /// at the running executable — never cwd/`PATH` probing (DLL hijacking).
  /// Debug builds additionally try cwd-anchored project paths so
  /// `flutter run` works without installing the library.
  static DynamicLibrary? _loadLibrary() {
    final String fileName;
    if (Platform.isWindows) {
      fileName = 'netstudio_engine.dll';
    } else if (Platform.isLinux || Platform.isAndroid) {
      fileName = 'libnetstudio_engine.so';
    } else if (Platform.isMacOS || Platform.isIOS) {
      fileName = 'libnetstudio_engine.dylib';
    } else {
      return null;
    }

    final List<String> candidates = [];
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir${Platform.pathSeparator}$fileName');
    } catch (_) {}

    // Dev convenience (debug builds ONLY): <project> paths anchored at
    // the working directory. Resolving them absolutely does NOT make them
    // safe — cwd is attacker-influenced — so release builds skip them and
    // load exclusively from the executable directory above.
    if (kDebugMode) {
      try {
        final root = Directory.current.path;
        candidates.addAll([
          '$root${Platform.pathSeparator}$fileName',
          '$root${Platform.pathSeparator}native_engine${Platform.pathSeparator}target${Platform.pathSeparator}release${Platform.pathSeparator}$fileName',
          '$root${Platform.pathSeparator}native_engine${Platform.pathSeparator}target${Platform.pathSeparator}debug${Platform.pathSeparator}$fileName',
        ]);
      } catch (_) {}
    }

    for (final path in candidates) {
      // Skip anything that is not an absolute path.
      final f = File(path);
      if (!f.isAbsolute) continue;
      try {
        if (!f.existsSync()) continue;
        final lib = DynamicLibrary.open(path);
        _loadedPath = path;
        return lib;
      } catch (_) {
        // Try next candidate.
      }
    }
    return null;
  }
}

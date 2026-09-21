import 'dart:ffi';
import 'dart:io';

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

  /// Secure load: only from absolute paths anchored at the running
  /// executable (or the project root during `flutter run`), never from
  /// cwd-relative / PATH probing which enables DLL hijacking.
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

    // Dev convenience: <project>/native_engine/target/{release,debug}
    // resolved absolutely from the executable location is not reliable
    // under `flutter run`, so also try cwd-anchored absolute paths.
    try {
      final root = Directory.current.path;
      candidates.addAll([
        '$root${Platform.pathSeparator}$fileName',
        '$root${Platform.pathSeparator}native_engine${Platform.pathSeparator}target${Platform.pathSeparator}release${Platform.pathSeparator}$fileName',
        '$root${Platform.pathSeparator}native_engine${Platform.pathSeparator}target${Platform.pathSeparator}debug${Platform.pathSeparator}$fileName',
      ]);
    } catch (_) {}

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

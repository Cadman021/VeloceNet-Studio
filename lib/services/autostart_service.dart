import 'dart:io';

import 'package:flutter/foundation.dart';

/// Launch-at-login support, implemented without a plugin so the release
/// matrix gains no new native dependency.
///
/// - Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` via
///   `reg.exe` (per-user, no elevation, matches the NSIS/portable story).
/// - Linux: an XDG autostart `.desktop` entry under
///   `$XDG_CONFIG_HOME/autostart` (works under GNOME/KDE/XFCE).
/// - macOS: unsupported for now (needs a LaunchAgent plist + signing
///   decisions); [isSupported] returns false and the Settings toggle is
///   hidden rather than lying.
///
/// Every call is best-effort: a failure returns false instead of throwing,
/// so a locked-down registry or read-only home directory degrades to "not
/// enabled" without breaking startup.
class AutostartService {
  AutostartService({
    @visibleForTesting String? executableOverride,
    @visibleForTesting String? linuxConfigHomeOverride,
  })  : _executableOverride = executableOverride,
        _linuxConfigHomeOverride = linuxConfigHomeOverride;

  /// Test seam: lets the unit tests pin a fake executable path instead of
  /// the test runner binary.
  final String? _executableOverride;

  /// Test seam: overrides the XDG config home so the Linux round-trip can
  /// run against a temp directory instead of the developer's real profile.
  final String? _linuxConfigHomeOverride;

  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _valueName = 'VeloceNetStudio';
  static const String _desktopFileName = 'velocenet-studio.desktop';

  /// Whether launch-at-login can be configured on this platform.
  static bool get isSupported => Platform.isWindows || Platform.isLinux;

  String get _executable =>
      _executableOverride ?? Platform.resolvedExecutable;

  /// True when an autostart entry currently exists for this user.
  Future<bool> isEnabled() async {
    try {
      if (Platform.isWindows) return await _isEnabledWindows();
      if (Platform.isLinux) return await _isEnabledLinux();
    } catch (_) {}
    return false;
  }

  /// Creates or removes the autostart entry. Returns true on success.
  Future<bool> setEnabled(bool enabled) async {
    try {
      if (Platform.isWindows) return await _setEnabledWindows(enabled);
      if (Platform.isLinux) return await _setEnabledLinux(enabled);
    } catch (_) {}
    return false;
  }

  // ---------------------------------------------------------------------
  // Windows
  // ---------------------------------------------------------------------

  Future<bool> _isEnabledWindows() async {
    final out = await _run(['reg', 'query', _runKey, '/v', _valueName]);
    return out != null && out.exitCode == 0;
  }

  Future<bool> _setEnabledWindows(bool enabled) async {
    if (enabled) {
      // reg add with /f overwrites an existing value, so re-enabling after
      // moving the install directory repoints the path correctly.
      final result = await _run([
        'reg',
        'add',
        _runKey,
        '/v',
        _valueName,
        '/t',
        'REG_SZ',
        '/d',
        '"$_executable"',
        '/f',
      ]);
      return result != null && result.exitCode == 0;
    }
    // A missing value makes `reg delete` exit non-zero; that already means
    // "not enabled", so treat it as success.
    final result = await _run(['reg', 'delete', _runKey, '/v', _valueName, '/f']);
    if (result == null) return false;
    return result.exitCode == 0 || result.exitCode == 1;
  }

  Future<ProcessResult?> _run(List<String> args) async {
    try {
      return await Process.run(args.first, args.sublist(1));
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Linux
  // ---------------------------------------------------------------------

  File get _desktopFile {
    final configHome =
        _linuxConfigHomeOverride ?? Platform.environment['XDG_CONFIG_HOME'];
    final base = (configHome != null && configHome.isNotEmpty)
        ? configHome
        : '${Platform.environment['HOME'] ?? ''}/.config';
    return File('$base/autostart/$_desktopFileName');
  }

  /// The `.desktop` path this instance would use. Exposed so tests can
  /// assert the exact location without reimplementing the XDG rule.
  @visibleForTesting
  File get linuxDesktopFile => _desktopFile;

  Future<bool> _isEnabledLinux() async {
    try {
      return await _desktopFile.exists();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _setEnabledLinux(bool enabled) async {
    final file = _desktopFile;
    if (!enabled) {
      try {
        if (await file.exists()) await file.delete();
        return true;
      } catch (_) {
        return false;
      }
    }
    try {
      await file.parent.create(recursive: true);
      // Exec is quoted so install paths with spaces survive parsing.
      final content = '[Desktop Entry]\n'
          'Type=Application\n'
          'Name=VeloceNet-Studio\n'
          'Comment=Network Monitor & Analysis\n'
          'Exec="$_executable"\n'
          'Terminal=false\n'
          'X-GNOME-Autostart-enabled=true\n';
      await file.writeAsString(content);
      return true;
    } catch (_) {
      return false;
    }
  }
}

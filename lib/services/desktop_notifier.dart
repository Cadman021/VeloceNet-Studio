import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

import '../models/alert_event.dart';
import '../state/alert_log.dart';
import 'webhook_dispatcher.dart' show formatAlertMessage;

/// One-time native notification setup (Windows uses a Start-Menu shortcut
/// to obtain a toast AppUserModelID; Linux needs libnotify; macOS uses the
/// system notification center).
///
/// Failures are non-fatal: the rest of the app (including webhooks) keeps
/// working, and Settings surfaces that desktop notifications are
/// unavailable instead of silently pretending they were delivered.
class DesktopNotificationSupport {
  DesktopNotificationSupport._();

  static bool initialized = false;
  static String? lastError;

  static bool get isPlatformSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Call once from `main()`. No-op in tests (plugin channels hang there)
  /// and on unsupported platforms.
  static Future<void> initialize({String appName = 'VeloceNet-Studio'}) async {
    if (initialized || !isPlatformSupported) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      await localNotifier.setup(
        appName: appName,
        // Windows needs a real shortcut for toasts to be delivered; ignored
        // by the Linux/macOS implementations.
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      initialized = true;
      lastError = null;
    } catch (e) {
      lastError = '$e';
      debugPrint('Desktop notifications unavailable: $e');
    }
  }
}

/// Bridges [AlertLog] transitions to native OS notifications.
///
/// Every transition recorded since the last listener call is delivered,
/// because a burst (e.g. several targets going down at once) should not
/// collapse into one toast. The AlertLog itself already suppresses
/// duplicate/no-op transitions and muted targets emit no events at all.
class DesktopNotifier {
  final AlertLog log;
  final bool Function() isEnabled;
  final String Function() templateOf;

  int _lastSeenId = 0;
  bool _disposed = false;

  DesktopNotifier({
    required this.log,
    required this.isEnabled,
    required this.templateOf,
  }) {
    _lastSeenId = log.events.isEmpty ? 0 : log.events.first.id;
    log.addListener(_onLog);
  }

  bool get isAvailable =>
      DesktopNotificationSupport.initialized &&
      DesktopNotificationSupport.isPlatformSupported;

  void _onLog() {
    if (_disposed) return;
    final fresh = log.events.where((e) => e.id > _lastSeenId).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (log.events.isNotEmpty) _lastSeenId = log.events.first.id;
    if (!isEnabled() || !isAvailable) return;
    for (final event in fresh) {
      unawaited(_show(event));
    }
  }

  Future<void> _show(AlertEvent event) async {
    try {
      final notification = LocalNotification(
        title: 'VeloceNet — ${event.targetName}',
        body: formatAlertMessage(event, template: templateOf()),
      );
      await notification.show();
    } catch (e) {
      debugPrint('Desktop notification failed: $e');
    }
  }

  /// Shows an explicit test notification. Returns false when the platform
  /// or the native setup is unavailable (the caller shows a friendly hint).
  Future<bool> test({required String title, required String body}) async {
    if (!isAvailable) {
      // Enabling the toggle may have kicked off setup asynchronously; give
      // it one more chance before reporting unavailable.
      await DesktopNotificationSupport.initialize();
    }
    if (!isAvailable) return false;
    try {
      await LocalNotification(title: title, body: body).show();
      return true;
    } catch (e) {
      debugPrint('Desktop notification test failed: $e');
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    log.removeListener(_onLog);
  }
}

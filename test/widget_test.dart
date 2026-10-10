// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:netstudio/core/i18n/app_strings.dart';
import 'package:netstudio/core/settings/settings_controller.dart';
import 'package:netstudio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Empty stand-in for the OS credential store. NOTE (hard-won): an
/// UNMOCKED plugin channel hangs widget tests forever instead of throwing
/// MissingPluginException — every plugin the app touches at startup needs
/// a mock here (or a FLUTTER_TEST guard at the call site, like tray setup).
void _mockSecureStorage() {
  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);
}

void main() {
  testWidgets('NetStudio app smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    _mockSecureStorage();
    await AppStrings.ensureLoaded();
    final settings = SettingsController();
    await settings.load();
    // Desktop-sized surface: sidebar (250) + content need width.
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // Build our app and trigger a frame.
    await tester.pumpWidget(NetStudioApp(settings: settings));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Verify that the shell renders (brand appears in sidebar).
    expect(find.text('VeloceNet-Studio'), findsWidgets);
  });
}

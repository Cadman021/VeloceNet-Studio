import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netstudio/core/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

MockClient _clientFor(String tag) {
  return MockClient((_) async => http.Response(
        '{"tag_name": "$tag", "html_url": "https://x/y", "body": "notes"}',
        200,
      ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('update dialog gating', () {
    test('shows once per version, re-triggers on newer', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      expect(settings.shouldShowUpdateDialog, isFalse);

      expect(
        await settings.checkForUpdates(
            force: true, client: _clientFor('v9.9.9')),
        isTrue,
      );
      expect(settings.latestKnownVersion, '9.9.9');
      expect(settings.shouldShowUpdateDialog, isTrue);

      await settings.dismissUpdate('9.9.9');
      expect(settings.shouldShowUpdateDialog, isFalse);

      // Same version again: still dismissed.
      expect(
        await settings.checkForUpdates(
            force: true, client: _clientFor('v9.9.9')),
        isTrue,
      );
      expect(settings.shouldShowUpdateDialog, isFalse);

      // Newer release: dialog again.
      expect(
        await settings.checkForUpdates(
            force: true, client: _clientFor('v10.0.0')),
        isTrue,
      );
      expect(settings.shouldShowUpdateDialog, isTrue);
    });

    test('opted-out auto checks never hit the network', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      await settings.setUpdateCheckEnabled(false);
      var called = false;
      final result = await settings.checkForUpdates(
        client: MockClient((_) async {
          called = true;
          throw const SocketException('must not be called');
        }),
      );
      expect(called, isFalse);
      expect(result, isFalse);
      // Manual checks bypass the opt-out.
      expect(
        await settings.checkForUpdates(
            force: true, client: _clientFor('v9.9.9')),
        isTrue,
      );
    });

    test('up-to-date clears a stale known version', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsController();
      await settings.load();
      await settings.checkForUpdates(
          force: true, client: _clientFor('v9.9.9'));
      expect(settings.shouldShowUpdateDialog, isTrue);
      await settings.checkForUpdates(
          force: true, client: _clientFor('v0.0.1'));
      expect(settings.latestKnownVersion, isNull);
      expect(settings.shouldShowUpdateDialog, isFalse);
    });
  });
}

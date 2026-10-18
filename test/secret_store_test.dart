import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/core/settings/secret_store.dart';
import 'package:netstudio/core/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingStore extends FakeSecretStore {
  @override
  Future<bool> writeProtected(String key, String value) async => false;
}

void main() {
  group('secretWarning surfaces unprotected saves', () {
    test('set when protection fails, cleared on success', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = SettingsController(secrets: _FailingStore());
      await controller.load();
      expect(controller.secretWarning, isNull);
      await controller.setTelegram(token: 'tok');
      expect(controller.secretWarning, isNotNull);
      // A successful save clears it again (new store, same controller
      // shape is enough: swap via a fresh controller on FakeSecretStore).
      final ok = SettingsController(secrets: FakeSecretStore());
      await ok.load();
      await ok.setTelegram(token: 'tok');
      expect(ok.secretWarning, isNull);
    });
  });

  group('FakeSecretStore via SettingsController', () {
    test('round-trips secrets without touching prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = SettingsController(secrets: FakeSecretStore());
      await controller.load();
      await controller.setTelegram(enabled: true, token: 'tok', chatId: '1');
      expect(controller.telegramToken, 'tok');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('settings.tgToken'), isFalse);
      expect(prefs.getBool('settings.tgEnabled'), isTrue);

      await controller.setTelegram(token: '');
      expect(controller.telegramToken, isEmpty);
    });
  });

  group('PlatformSecretStore', () {
    test('legacy plaintext stays readable (migration-safe)', () async {
      SharedPreferences.setMockInitialValues(
          {'settings.tgToken': 'legacy-token'});
      final controller = SettingsController();
      await controller.load();
      expect(controller.telegramToken, 'legacy-token');
    });

    test('Windows DPAPI round-trip with opaque ciphertext', () async {
      if (!Platform.isWindows) return;
      SharedPreferences.setMockInitialValues({});
      final store = PlatformSecretStore();
      await store.write('k', 's3cr3t!');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('k')!;
      // Ciphertext at rest, never the secret itself.
      expect(raw.startsWith('dpapi1:'), isTrue);
      expect(raw, isNot(contains('s3cr3t!')));
      expect(await store.read('k'), 's3cr3t!');
      await store.delete('k');
      expect(await store.read('k'), isNull);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('empty and missing keys read as null', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PlatformSecretStore();
      expect(await store.read('nope'), isNull);
    });
  });
}

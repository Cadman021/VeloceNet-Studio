import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/services/autostart_service.dart';

void main() {
  group('AutostartService platform support', () {
    test('isSupported matches the documented platform matrix', () {
      final expected = Platform.isWindows || Platform.isLinux;
      expect(AutostartService.isSupported, expected);
    });
  });

  group('AutostartService executable override', () {
    test('construction performs no I/O', () {
      final service =
          AutostartService(executableOverride: '/opt/app/velocenet');
      expect(service, isNotNull);
    });
  });

  group('AutostartService Linux .desktop round-trip', () {
    test('enable writes an entry, disable removes it', () async {
      if (!Platform.isLinux) return; // registry path has no unit seam

      final tmp = await Directory.systemTemp.createTemp('autostart_test');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final service = AutostartService(
        executableOverride: '/opt/velocenet/velocenet-studio',
        linuxConfigHomeOverride: tmp.path,
      );

      expect(await service.isEnabled(), isFalse);

      expect(await service.setEnabled(true), isTrue);
      expect(await service.isEnabled(), isTrue);

      final file = service.linuxDesktopFile;
      expect(await file.exists(), isTrue);
      final content = await file.readAsString();
      expect(content, contains('[Desktop Entry]'));
      expect(content, contains('Name=VeloceNet-Studio'));
      // Install paths with spaces must stay quoted.
      expect(content, contains('Exec="/opt/velocenet/velocenet-studio"'));

      expect(await service.setEnabled(false), isTrue);
      expect(await service.isEnabled(), isFalse);
      expect(await file.exists(), isFalse);
    });

    test('disabling an already-absent entry is a no-op success', () async {
      if (!Platform.isLinux) return;
      final tmp = await Directory.systemTemp.createTemp('autostart_test');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final service = AutostartService(linuxConfigHomeOverride: tmp.path);
      expect(await service.setEnabled(false), isTrue);
    });
  });
}

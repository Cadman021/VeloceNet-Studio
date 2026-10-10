import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netstudio/services/update_checker.dart';

void main() {
  group('compareVersions', () {
    test('numeric dotted comparison with v-prefix tolerance', () {
      expect(compareVersions('1.2.0', '1.3.0'), -1);
      expect(compareVersions('v1.3.0', '1.3.0'), 0);
      expect(compareVersions('1.10.0', '1.9.0'), 1);
      expect(compareVersions('1.3', '1.3.0'), 0);
      expect(compareVersions('2.0.0', '10.0.0'), -1);
      expect(compareVersions('1.3.0-beta', '1.3.0'), 0);
      expect(compareVersions('garbage', '1.0.0'), -1);
    });
  });

  group('shouldAutoCheck', () {
    test('daily throttle', () {
      final now = DateTime.utc(2026, 10, 10, 12);
      expect(shouldAutoCheck(null, now), isTrue);
      expect(
          shouldAutoCheck(now.subtract(const Duration(hours: 23)), now),
          isFalse);
      expect(
          shouldAutoCheck(now.subtract(const Duration(hours: 25)), now),
          isTrue);
    });
  });

  group('fetchLatestRelease', () {
    test('parses tag, url and notes', () async {
      final client = MockClient((request) async {
        expect(request.headers['Accept'],
            'application/vnd.github+json');
        return http.Response(
          '{"tag_name": "v1.4.0", '
          '"html_url": "https://github.com/x/y/releases/tag/v1.4.0", '
          '"body": "notes here"}',
          200,
        );
      });
      final info = await fetchLatestRelease(client: client);
      expect(info, isNotNull);
      expect(info!.version, '1.4.0');
      expect(info.url, contains('v1.4.0'));
      expect(info.notes, 'notes here');
    });

    test('failures yield null, never throw', () async {
      expect(
        await fetchLatestRelease(
          client: MockClient((_) async => http.Response('nope', 404)),
        ),
        isNull,
      );
      expect(
        await fetchLatestRelease(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        isNull,
      );
      expect(
        await fetchLatestRelease(
          client: MockClient((_) async => throw const SocketException('nope')),
        ),
        isNull,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/views/traceroute/traceroute_controller.dart';

void main() {
  group('normalizeTraceHost', () {
    test('accepts IPv4', () {
      expect(TracerouteController.normalizeTraceHost('8.8.8.8'), '8.8.8.8');
    });

    test('rejects out-of-range IPv4 octets', () {
      expect(TracerouteController.normalizeTraceHost('999.1.1.1'), isNull);
      expect(TracerouteController.normalizeTraceHost('1.2.3.256'), isNull);
    });

    test('accepts IPv6 with and without brackets', () {
      expect(
        TracerouteController.normalizeTraceHost('2001:4860:4860::8888'),
        '2001:4860:4860::8888',
      );
      expect(
        TracerouteController.normalizeTraceHost('[2001:4860:4860::8888]'),
        '2001:4860:4860::8888',
      );
    });

    test('accepts hostnames and strips URL wrappers', () {
      expect(
        TracerouteController.normalizeTraceHost('https://github.com/org'),
        'github.com',
      );
      expect(
        TracerouteController.normalizeTraceHost(' example.com '),
        'example.com',
      );
    });

    test('rejects empty, oversized and shell metacharacters', () {
      expect(TracerouteController.normalizeTraceHost(''), isNull);
      expect(TracerouteController.normalizeTraceHost('   '), isNull);
      expect(TracerouteController.normalizeTraceHost('a' * 254), isNull);
      // These must never reach Process.start as arguments.
      expect(TracerouteController.normalizeTraceHost('8.8.8.8; rm -rf /'), isNull);
      expect(TracerouteController.normalizeTraceHost('host | cat /etc/passwd'), isNull);
      expect(TracerouteController.normalizeTraceHost('\$(whoami)'), isNull);
      expect(TracerouteController.normalizeTraceHost('-h 1 8.8.8.8'), isNull);
    });
  });

  group('start validation', () {
    test('invalid host sets error instead of starting', () {
      final controller = TracerouteController();
      controller.start('not a host!!');
      expect(controller.isRunning, isFalse);
      expect(controller.progress.error, isNotNull);
      controller.dispose();
    });
  });
}

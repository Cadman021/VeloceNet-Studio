import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/core/validation/host_validator.dart';
import 'package:netstudio/views/traceroute/traceroute_controller.dart';

void main() {
  group('normalizeTraceHost', () {
    test('accepts IPv4', () {
      expect(normalizeTraceHost('8.8.8.8'), '8.8.8.8');
    });

    test('rejects out-of-range IPv4 octets', () {
      expect(normalizeTraceHost('999.1.1.1'), isNull);
      expect(normalizeTraceHost('1.2.3.256'), isNull);
    });

    test('accepts IPv6 with and without brackets', () {
      expect(
        normalizeTraceHost('2001:4860:4860::8888'),
        '2001:4860:4860::8888',
      );
      expect(
        normalizeTraceHost('[2001:4860:4860::8888]'),
        '2001:4860:4860::8888',
      );
    });

    test('accepts trailing-dot FQDN form', () {
      expect(normalizeTraceHost('example.com.'), 'example.com');
      expect(normalizeTraceHost('[2001:db8::1]'), '2001:db8::1');
    });

    test('accepts hostnames and strips URL wrappers', () {
      expect(
        normalizeTraceHost('https://github.com/org'),
        'github.com',
      );
      expect(
        normalizeTraceHost(' example.com '),
        'example.com',
      );
    });

    test('rejects empty, oversized and shell metacharacters', () {
      expect(normalizeTraceHost(''), isNull);
      expect(normalizeTraceHost('   '), isNull);
      expect(normalizeTraceHost('a' * 254), isNull);
      // These must never reach Process.start as arguments.
      expect(normalizeTraceHost('8.8.8.8; rm -rf /'), isNull);
      expect(normalizeTraceHost('host | cat /etc/passwd'), isNull);
      expect(normalizeTraceHost('\$(whoami)'), isNull);
      expect(normalizeTraceHost('-h 1 8.8.8.8'), isNull);
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

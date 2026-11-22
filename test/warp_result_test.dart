import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/warp_result.dart';

void main() {
  group('WarpResult.viaTcpFallback', () {
    test('distinguishes real UDP success from TCP-indicated', () {
      const udp = WarpResult(
        ip: '1.1.1.1',
        port: 443,
        endpoint: '1.1.1.1:443',
        rttMs: 12.0,
        success: true,
      );
      const tcp = WarpResult(
        ip: '1.1.1.1',
        port: 443,
        endpoint: '1.1.1.1:443',
        rttMs: 30.0,
        success: true,
        note: 'via TCP fallback (UDP filtered)',
      );
      const failed = WarpResult(
        ip: '1.1.1.1',
        port: 443,
        endpoint: '1.1.1.1:443',
        rttMs: -1.0,
        success: false,
      );
      expect(udp.viaTcpFallback, isFalse);
      expect(tcp.viaTcpFallback, isTrue);
      expect(failed.viaTcpFallback, isFalse);
    });
  });

  group('WarpResult.handshake', () {
    test('defaults false and parses the native handshake flag', () {
      const legacy = WarpResult(
        ip: '1.1.1.1',
        port: 443,
        endpoint: '1.1.1.1:443',
        rttMs: 10,
        success: true,
      );
      expect(legacy.handshake, isFalse);

      final parsed = WarpResult.fromJson({
        'ip': '1.1.1.1',
        'port': 443,
        'endpoint': '1.1.1.1:443',
        'rttMs': 12.5,
        'success': true,
        'handshake': true,
        'error': 'WireGuard handshake',
      });
      expect(parsed.handshake, isTrue);
      expect(parsed.viaTcpFallback, isFalse);
    });

    test('TCP fallback success is not a handshake', () {
      final parsed = WarpResult.fromJson({
        'ip': '1.1.1.1',
        'port': 443,
        'endpoint': '1.1.1.1:443',
        'rttMs': 30.0,
        'success': true,
        'handshake': false,
        'error': 'via TCP fallback (UDP filtered)',
      });
      expect(parsed.success, isTrue);
      expect(parsed.handshake, isFalse);
      expect(parsed.viaTcpFallback, isTrue);
    });
  });
}

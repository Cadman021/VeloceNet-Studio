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
}

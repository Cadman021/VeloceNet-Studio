import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/port_scan.dart';

void main() {
  group('parsePortSpec', () {
    test('parses singles, ranges and dedupes sorted', () {
      expect(parsePortSpec('443,80,8000-8002,80'), [80, 443, 8000, 8001, 8002]);
    });

    test('rejects malformed specs', () {
      expect(parsePortSpec(''), isNull);
      expect(parsePortSpec('   '), isNull);
      expect(parsePortSpec('0'), isNull);
      expect(parsePortSpec('65536'), isNull);
      expect(parsePortSpec('80-'), isNull);
      expect(parsePortSpec('-80'), isNull);
      expect(parsePortSpec('100-80'), isNull);
      expect(parsePortSpec('abc'), isNull);
      expect(parsePortSpec('80,,443'), [80, 443]);
    });

    test('enforces the port cap', () {
      expect(parsePortSpec('1-5000', maxPorts: 4096), isNull);
      expect(parsePortSpec('1-4096', maxPorts: 4096), hasLength(4096));
    });
  });

  group('serviceForPort', () {
    test('knows common services, empty otherwise', () {
      expect(serviceForPort(22), 'SSH');
      expect(serviceForPort(443), 'HTTPS');
      expect(serviceForPort(5432), 'Postgres');
      expect(serviceForPort(9999), isEmpty);
    });
  });
}

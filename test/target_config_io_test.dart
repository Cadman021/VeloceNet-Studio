import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/ping_target.dart';
import 'package:netstudio/services/target_config_io.dart';

PingTarget _target({int id = 1, String host = '1.1.1.1'}) {
  return PingTarget(id: id, name: 't$id', host: host);
}

void main() {
  group('exportTargetsJson', () {
    test('round-trips through the importer', () {
      final json = exportTargetsJson([_target(), _target(id: 2, host: '8.8.8.8')]);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['app'], 'velocenet-studio');
      expect(decoded['version'], kTargetBackupVersion);
      final result = importTargetsJson(json);
      expect(result.targets, hasLength(2));
      expect(result.skipped, 0);
      // Stored ids are ignored (reassigned on import).
      expect(result.targets.first.id, 0);
      expect(result.targets[1].host, '8.8.8.8');
    });

    test('accepts a bare array too', () {
      final result = importTargetsJson('[{"host": "1.1.1.1"}]');
      expect(result.targets, hasLength(1));
      // Defaults applied, name falls back to host.
      expect(result.targets.first.name, '1.1.1.1');
      expect(result.targets.first.port, 80);
      expect(result.targets.first.protocol, NetworkProtocol.icmp);
    });
  });

  group('importTargetsJson validation', () {
    test('rejects garbage without throwing', () {
      expect(importTargetsJson('').targets, isEmpty);
      expect(importTargetsJson('not json').targets, isEmpty);
      expect(importTargetsJson('{"targets": {}}').targets, isEmpty);
      expect(importTargetsJson('[42]').skipped, 1);
    });

    test('skips bad hosts, ports and shapes, keeps the rest', () {
      const raw = '''
      {"targets": [
        {"host": "1.1.1.1", "port": 53, "protocol": 0},
        {"host": "8.8.8.8; rm -rf /", "port": 53},
        {"host": "9.9.9.9", "port": 99999},
        {"host": "github.com", "port": "443", "protocol": "TCP"},
        {"nope": true},
        {"host": "2620:fe::fe", "port": 53}
      ]}
      ''';
      final result = importTargetsJson(raw);
      expect(result.targets.map((t) => t.host),
          ['1.1.1.1', 'github.com', '2620:fe::fe']);
      expect(result.targets[1].protocol, NetworkProtocol.tcp);
      expect(result.skipped, 3);
    });

    test('clamps intervals and truncates long names', () {
      final result = importTargetsJson(
        '[{"host": "1.1.1.1", "interval_ms": 5, "timeout_ms": 999999, '
        '"name": "${'x' * 200}"}]',
      );
      final t = result.targets.single;
      expect(t.intervalMs, 200);
      expect(t.timeoutMs, 10000);
      expect(t.name, hasLength(128));
    });

    test('caps entry count', () {
      final many = List.generate(
          kMaxImportTargets + 5, (i) => '{"host": "10.0.0.1", "port": 80}');
      final result = importTargetsJson('[${many.join(',')}]');
      expect(result.targets, hasLength(kMaxImportTargets));
      expect(result.skipped, 5);
    });
  });
}

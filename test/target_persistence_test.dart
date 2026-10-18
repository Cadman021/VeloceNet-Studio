import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/ping_target.dart';
import 'package:netstudio/services/target_config_io.dart';
import 'package:netstudio/state/ping_matrix_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('decodePersistedTargets', () {
    test('keeps validated ids, drops dupes and garbage', () {
      const raw = '''
      {"app": "velocenet-studio", "version": 1, "targets": [
        {"id": 101, "host": "1.1.1.1", "port": 53},
        {"id": 102, "host": "8.8.8.8"},
        {"id": 101, "host": "9.9.9.9"},
        {"host": "bad host !!"},
        {"id": -5, "host": "1.0.0.1"}
      ]}
      ''';
      final targets = decodePersistedTargets(raw)!;
      expect(targets.map((t) => t.id), [101, 102]);
      expect(targets.first.host, '1.1.1.1');
    });

    test('null on garbage, empty and missing shapes', () {
      expect(decodePersistedTargets(''), isNull);
      expect(decodePersistedTargets('nope'), isNull);
      expect(decodePersistedTargets('{"targets": []}'), isNull);
      expect(decodePersistedTargets('{"targets": {}}'), isNull);
    });
  });

  group('group & tag sanitization', () {
    test('sanitizeGroup trims, caps and empty→null', () {
      expect(PingTarget.sanitizeGroup(null), isNull);
      expect(PingTarget.sanitizeGroup('  '), isNull);
      expect(PingTarget.sanitizeGroup('  TEH  '), 'TEH');
      final long = 'g' * 100;
      expect(PingTarget.sanitizeGroup(long)!.length, PingTarget.maxGroupLength);
    });

    test('sanitizeTags trims, dedupes case-insensitively, caps count/length',
        () {
      expect(PingTarget.sanitizeTags([' a ', 'A', 'b', '', '  ']), ['a', 'b']);
      final long = 't' * 50;
      expect(PingTarget.sanitizeTags([long]).single.length,
          PingTarget.maxTagLength);
      final many = List.generate(20, (i) => 'tag$i');
      expect(PingTarget.sanitizeTags(many).length, PingTarget.maxTags);
    });

    test('parseTags tolerates list, comma string and garbage', () {
      expect(PingTarget.parseTags([' a ', 'A', 'b']), ['a', 'b']);
      expect(PingTarget.parseTags('prod, dns، edge'), ['prod', 'dns', 'edge']);
      expect(PingTarget.parseTags(42), isEmpty);
      expect(PingTarget.parseTags(null), isEmpty);
    });

    test('json round-trip keeps group and tags', () {
      const t = PingTarget(
        id: 1,
        name: 'n',
        host: '1.1.1.1',
        group: 'DC1',
        tags: ['prod', 'dns'],
      );
      final back = PingTarget.fromJson(t.toJson());
      expect(back.group, 'DC1');
      expect(back.tags, ['prod', 'dns']);
    });

    test('import parses tags list, comma string and legacy singular tag', () {
      const raw = '''
      {"targets": [
        {"host": "1.1.1.1", "tags": ["a", "b"]},
        {"host": "8.8.8.8", "tags": "x, y"},
        {"host": "9.9.9.9", "tag": "solo"}
      ]}
      ''';
      final targets = importTargetsJson(raw).targets;
      expect(targets[0].tags, ['a', 'b']);
      expect(targets[1].tags, ['x', 'y']);
      expect(targets[2].tags, ['solo']);
    });

    test('persisted decode keeps group and tags', () {
      final raw = exportTargetsJson([
        const PingTarget(
            id: 7, name: 'n', host: '1.1.1.1', group: 'DC', tags: ['a']),
      ]);
      final restored = decodePersistedTargets(raw)!;
      expect(restored.single.group, 'DC');
      expect(restored.single.tags, ['a']);
    });
  });

  group('HTTP path sanitization', () {
    test('sanitizeHttpPath trims, adds slash, strips control chars, caps', () {
      expect(PingTarget.sanitizeHttpPath(null), '');
      expect(PingTarget.sanitizeHttpPath('  '), '');
      expect(PingTarget.sanitizeHttpPath('health'), '/health');
      expect(PingTarget.sanitizeHttpPath(' /health?x=1 '), '/health?x=1');
      expect(PingTarget.sanitizeHttpPath('/a\x00b'), '/ab');
      final long = '/${'p' * 400}';
      expect(PingTarget.sanitizeHttpPath(long).length,
          PingTarget.maxHttpPathLength);
    });

    test('json round-trip keeps http path and protocol', () {
      const t = PingTarget(
        id: 2,
        name: 'api',
        host: 'api.example.com',
        port: 443,
        protocol: NetworkProtocol.https,
        httpPath: '/health',
      );
      final back = PingTarget.fromJson(t.toJson());
      expect(back.protocol, NetworkProtocol.https);
      expect(back.httpPath, '/health');
      expect(NetworkProtocol.fromId(2), NetworkProtocol.http);
      expect(NetworkProtocol.fromId(3), NetworkProtocol.https);
    });
  });

  group('PingMatrixController persistence', () {
    test('init restores persisted targets, not defaults', () async {
      SharedPreferences.setMockInitialValues({
        'targets.v1': exportTargetsJson([
          const PingTarget(id: 4242, name: 'mine', host: '10.9.9.9'),
        ]),
      });
      final controller = PingMatrixController();
      await controller.init();
      expect(controller.targets.map((t) => t.id), [4242]);
      expect(controller.targets.single.host, '10.9.9.9');
      controller.dispose();
    });

    test('corrupt data falls back to defaults', () async {
      SharedPreferences.setMockInitialValues(
          {'targets.v1': 'definitely not json'});
      final controller = PingMatrixController();
      await controller.init();
      expect(controller.targets, isNotEmpty);
      expect(
        controller.targets.any((t) => t.host == '10.9.9.9'),
        isFalse,
      );
      controller.dispose();
    });

    test('toggleMute flips, persists and round-trips', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = PingMatrixController();
      await controller.init();
      controller.addTarget(
        const PingTarget(id: 888001, name: 'm', host: '8.8.8.8'),
      );
      expect(controller.targets.last.muted, isFalse);
      controller.toggleMute(888001);
      expect(controller.targets.last.muted, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final prefs = await SharedPreferences.getInstance();
      final restored = decodePersistedTargets(prefs.getString('targets.v1')!);
      expect(restored!.singleWhere((t) => t.id == 888001).muted, isTrue);
      controller.toggleMute(888001);
      expect(controller.targets.last.muted, isFalse);
      controller.dispose();
    });

    test('updateTarget replaces in place, persists, ignores unknown ids',
        () async {
      SharedPreferences.setMockInitialValues({});
      final controller = PingMatrixController();
      await controller.init();
      controller.addTarget(
        const PingTarget(id: 999001, name: 'old', host: '8.8.8.8'),
      );
      final before = controller.targets.length;

      controller.updateTarget(const PingTarget(
        id: 999001,
        name: 'new',
        host: '1.1.1.1',
        group: 'DC',
        tags: ['prod'],
      ));
      expect(controller.targets.length, before);
      final updated = controller.targets.singleWhere((t) => t.id == 999001);
      expect(updated.name, 'new');
      expect(updated.host, '1.1.1.1');

      controller.updateTarget(
        const PingTarget(id: 123456789, name: 'ghost', host: '1.1.1.1'),
      );
      expect(controller.targets.length, before);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      final prefs = await SharedPreferences.getInstance();
      final restored = decodePersistedTargets(prefs.getString('targets.v1')!);
      final persisted = restored!.singleWhere((t) => t.id == 999001);
      expect(persisted.group, 'DC');
      expect(persisted.tags, ['prod']);
      controller.dispose();
    });

    test('add/remove rewrite the persisted list', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = PingMatrixController();
      await controller.init();
      final before = controller.targets.length;

      controller.addTarget(
        const PingTarget(id: 777001, name: 'extra', host: '8.8.4.4'),
      );
      // Let the fire-and-forget persist land.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      var prefs = await SharedPreferences.getInstance();
      var restored = decodePersistedTargets(prefs.getString('targets.v1')!);
      expect(restored, isNotNull);
      expect(restored!.length, before + 1);

      controller.removeTarget(777001);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      prefs = await SharedPreferences.getInstance();
      restored = decodePersistedTargets(prefs.getString('targets.v1')!);
      expect(restored!.length, before);
      controller.dispose();
    });
  });
}

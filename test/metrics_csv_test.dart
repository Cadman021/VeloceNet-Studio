import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/ping_metric.dart';
import 'package:netstudio/services/metrics_csv.dart';

PingMetric _metric({
  int id = 1,
  String name = 'Cloudflare',
  String host = '1.1.1.1',
}) {
  return PingMetric(
    id: id,
    name: name,
    host: host,
    port: 53,
    protocol: 'ICMP',
    status: TargetStatus.online,
    sentCount: 10,
    receivedCount: 9,
    lostCount: 1,
    lossRate: 10.0,
    lastRttMs: 22.5,
    minRttMs: 18.0,
    maxRttMs: 40.0,
    avgRttMs: 24.0,
    jitterMs: 2.5,
    history: const [20.0, 22.5],
    lastCheckedEpochMs: 1726857600000,
  );
}

void main() {
  group('buildMetricsCsv', () {
    test('header plus one sorted row', () {
      final csv = buildMetricsCsv({2: _metric(id: 2), 1: _metric(id: 1)});
      final lines = csv.trim().split('\n');
      expect(lines.first,
          'id,name,host,port,protocol,status,sent,received,lost,loss_pct,last_ms,min_ms,max_ms,avg_ms,jitter_ms,checked_at_iso');
      expect(lines, hasLength(3));
      expect(lines[1].startsWith('1,Cloudflare,'), isTrue);
      expect(lines[2].startsWith('2,Cloudflare,'), isTrue);
      expect(lines[1], contains('10.00')); // loss_pct fixed decimals
    });

    test('RFC 4180 quoting for commas and quotes', () {
      final csv = buildMetricsCsv({
        1: _metric(name: 'Frankfurt, "main"'),
      });
      expect(csv, contains('"Frankfurt, ""main"""'));
    });

    test('empty metrics yields header only', () {
      final csv = buildMetricsCsv({});
      expect(csv.trim().split('\n'), hasLength(1));
    });

    test('formula cells are neutralized, never executed', () {
      final csv = buildMetricsCsv({
        1: _metric(name: '=cmd|calc!A1'),
        2: _metric(id: 2, name: '+7920555', host: '@evil'),
      });
      expect(csv, contains('"\'=cmd|calc!A1"'));
      expect(csv, contains('"\'@evil"'));
      expect(csv, isNot(contains(',=cmd')));
    });

    test('never-checked targets leave the timestamp empty, not 1970', () {
      final m = _metric();
      final csv = buildMetricsCsv({
        1: PingMetric(
          id: 1,
          name: m.name,
          host: m.host,
          port: m.port,
          protocol: m.protocol,
          status: TargetStatus.pending,
          sentCount: 0,
          receivedCount: 0,
          lostCount: 0,
          lossRate: 0.0,
          lastRttMs: 0.0,
          minRttMs: 0.0,
          maxRttMs: 0.0,
          avgRttMs: 0.0,
          jitterMs: 0.0,
          history: const [],
          lastCheckedEpochMs: 0,
        ),
      });
      expect(csv, isNot(contains('1970')));
      expect(csv.trim().split('\n').last.endsWith(','), isTrue);
    });
  });
}

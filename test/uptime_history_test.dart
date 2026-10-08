import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/ping_metric.dart';
import 'package:netstudio/services/uptime_history.dart';

PingMetric _metric(int id, TargetStatus status, double rtt) {
  return PingMetric(
    id: id,
    name: 't$id',
    host: '10.0.0.$id',
    port: 80,
    protocol: 'TCP',
    status: status,
    sentCount: 1,
    receivedCount: status == TargetStatus.online ? 1 : 0,
    lostCount: status == TargetStatus.online ? 0 : 1,
    lossRate: status == TargetStatus.online ? 0.0 : 100.0,
    lastRttMs: rtt,
    minRttMs: rtt,
    maxRttMs: rtt,
    avgRttMs: rtt,
    jitterMs: 0,
    history: const [],
    lastCheckedEpochMs: 0,
  );
}

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('uptime_history_test');

void main() {
  group('MinuteAccumulator', () {
    test('averages successes, counts losses, tracks worst status', () {
      final acc = MinuteAccumulator();
      acc.add(success: true, rttMs: 10.0, status: TargetStatus.online.index);
      acc.add(success: true, rttMs: 30.0, status: TargetStatus.degraded.index);
      acc.add(success: false, rttMs: -1.0, status: TargetStatus.offline.index);
      final b = acc.finalize(100);
      expect(b.avgRttMs, 20.0);
      expect(b.lossPct, closeTo(33.33, 0.01));
      expect(b.worstStatus, TargetStatus.offline.index);
    });

    test('json round-trip', () {
      const b = MinuteBucket(
          minute: 42, avgRttMs: 12.34, lossPct: 5.0, worstStatus: 1);
      final back = MinuteBucket.fromJson(b.toJson());
      expect(back.minute, 42);
      expect(back.avgRttMs, 12.3); // 0.1ms disk resolution
      expect(back.worstStatus, 1);
    });
  });

  group('findOutages', () {
    List<MinuteBucket> buckets(List<int> statuses, {int start = 1000}) {
      return [
        for (int i = 0; i < statuses.length; i++)
          MinuteBucket(
              minute: start + i,
              avgRttMs: 10,
              lossPct: 0,
              worstStatus: statuses[i]),
      ];
    }

    test('detects spans with worst severity and durations', () {
      final spans = findOutages(buckets([
        TargetStatus.online.index,
        TargetStatus.degraded.index,
        TargetStatus.offline.index,
        TargetStatus.online.index,
        TargetStatus.online.index,
        TargetStatus.offline.index,
      ]));
      expect(spans, hasLength(2));
      expect(spans[0].worstStatus, TargetStatus.offline.index);
      expect(spans[0].duration, const Duration(minutes: 2));
      expect(spans[1].duration, const Duration(minutes: 1));
    });

    test('all-online yields nothing, open span closes at end', () {
      expect(
          findOutages(
              buckets([TargetStatus.online.index, TargetStatus.online.index])),
          isEmpty);
      final open = findOutages(buckets(
          [TargetStatus.online.index, TargetStatus.offline.index]));
      expect(open, hasLength(1));
    });
  });

  group('UptimeHistoryService file round-trip', () {
    test('records frames, rolls minutes, reads back sorted', () async {
      final dir = await _tempDir();
      final svc = UptimeHistoryService(
          directoryProvider: () async => dir);
      await svc.init();
      expect(svc.isReady, isTrue);

      final t0 = DateTime.utc(2026, 9, 30, 12, 0);
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.online, 10.0)}, now: t0);
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.online, 20.0)},
          now: t0.add(const Duration(seconds: 30)));
      // Advance the clock: forces the minute rollover + flush.
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.degraded, 200.0)},
          now: t0.add(const Duration(minutes: 1)));
      await svc.flush();

      final buckets = await svc.bucketsFor(1, DateTime.utc(2026, 9, 30));
      expect(buckets, hasLength(2));
      expect(buckets[0].avgRttMs, 15.0);
      expect(buckets[1].worstStatus, TargetStatus.degraded.index);

      // Unknown target and unknown day are empty, never throw.
      expect(await svc.bucketsFor(999, DateTime.utc(2026, 9, 30)), isEmpty);
      expect(await svc.bucketsFor(1, DateTime.utc(2020, 1, 1)), isEmpty);
    });

    test('prunes files older than retention', () async {
      final dir = await _tempDir();
      final old = File('${dir.path}/VeloceNet-Studio/history/2020-01-01.json');
      await old.create(recursive: true);
      await old.writeAsString('{}');
      final svc = UptimeHistoryService(
          directoryProvider: () async => dir);
      await svc.init();
      expect(await old.exists(), isFalse);
    });
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/ping_metric.dart';
import 'package:netstudio/services/uptime_history.dart';

PingMetric _metric(int id, TargetStatus status, double rtt,
    {int sent = 1, int received = -1}) {
  final recv =
      received == -1 ? (status == TargetStatus.online ? 1 : 0) : received;
  return PingMetric(
    id: id,
    name: 't$id',
    host: '10.0.0.$id',
    port: 80,
    protocol: 'TCP',
    status: status,
    sentCount: sent,
    receivedCount: recv,
    lostCount: sent - recv,
    lossRate: sent == 0 ? 0.0 : (sent - recv) / sent * 100.0,
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
      final open = findOutages(
          buckets([TargetStatus.online.index, TargetStatus.offline.index]));
      expect(open, hasLength(1));
    });
  });

  group('UptimeHistoryService file round-trip', () {
    test('records frames, rolls minutes, reads back sorted', () async {
      final dir = await _tempDir();
      final svc = UptimeHistoryService(directoryProvider: () async => dir);
      await svc.init();
      expect(svc.isReady, isTrue);

      final t0 = DateTime(2026, 9, 30, 12, 0);
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.online, 10.0, sent: 1, received: 1)},
          now: t0);
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.online, 20.0, sent: 2, received: 2)},
          now: t0.add(const Duration(seconds: 30)));
      // Advance the clock: forces the minute rollover + flush.
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.degraded, 200.0, sent: 3, received: 2)},
          now: t0.add(const Duration(minutes: 1)));
      await svc.flush();

      final buckets = await svc.bucketsFor(1, DateTime(2026, 9, 30));
      expect(buckets, hasLength(2));
      expect(buckets[0].avgRttMs, 15.0);
      expect(buckets[0].lossPct, 0.0);
      expect(buckets[1].worstStatus, TargetStatus.degraded.index);
      expect(buckets[1].lossPct, 100.0);

      // Unknown target and unknown day are empty, never throw.
      expect(await svc.bucketsFor(999, DateTime(2026, 9, 30)), isEmpty);
      expect(await svc.bucketsFor(1, DateTime(2020, 1, 1)), isEmpty);
    });

    test('duplicate frames and pre-probe pending record nothing', () async {
      final dir = await _tempDir();
      final svc = UptimeHistoryService(directoryProvider: () async => dir);
      await svc.init();

      final t0 = DateTime(2026, 9, 30, 12, 0);
      // Pending target, zero counters: must not count as loss.
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.pending, 0.0, sent: 0, received: 0)},
          now: t0);
      // Same counters twice: no new probes, nothing recorded.
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.online, 10.0, sent: 5, received: 5)},
          now: t0.add(const Duration(seconds: 30)));
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.online, 10.0, sent: 5, received: 5)},
          now: t0.add(const Duration(minutes: 1)));
      await svc.flush();

      final buckets = await svc.bucketsFor(1, DateTime(2026, 9, 30));
      // Only the single genuine probe made it in; no phantom losses.
      expect(buckets, hasLength(1));
      expect(buckets.single.lossPct, 0.0);
    });

    test('writes append-only JSONL and splits at local midnight', () async {
      final dir = await _tempDir();
      final svc = UptimeHistoryService(directoryProvider: () async => dir);
      await svc.init();

      final late = DateTime(2026, 9, 30, 23, 59);
      final early = DateTime(2026, 10, 1, 0, 1);
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.online, 10.0, sent: 1, received: 1)},
          now: late);
      // Minute rollover flushes 23:59 into the Sep 30 log.
      await svc.recordFrame(
          {1: _metric(1, TargetStatus.online, 20.0, sent: 2, received: 2)},
          now: early);
      await svc.flush();

      final sepLog =
          File('${dir.path}/VeloceNet-Studio/history/2026-09-30.jsonl');
      final octLog =
          File('${dir.path}/VeloceNet-Studio/history/2026-10-01.jsonl');
      expect(await sepLog.exists(), isTrue);
      expect(await octLog.exists(), isTrue);
      final sepLines = (await sepLog.readAsLines())
          .where((line) => line.trim().isNotEmpty)
          .toList();
      expect(sepLines, hasLength(1));

      // Each bucket is one appended line, not a rewritten day map.
      expect(await svc.bucketsFor(1, DateTime(2026, 9, 30)), hasLength(1));
      expect(await svc.bucketsFor(1, DateTime(2026, 10, 1)), hasLength(1));
    });

    test('still reads legacy per-day map files', () async {
      final dir = await _tempDir();
      final svc = UptimeHistoryService(directoryProvider: () async => dir);
      await svc.init();

      final noon = DateTime(2026, 9, 30, 12, 0);
      final minute = noon.millisecondsSinceEpoch ~/ 60000;
      final history = Directory('${dir.path}/VeloceNet-Studio/history');
      await history.create(recursive: true);
      await File('${history.path}/2026-09-30.json').writeAsString(
        '{"1":[{"t":$minute,"avg":12.5,"loss":0.0,"s":${TargetStatus.online.index}}]}',
      );

      final buckets = await svc.bucketsFor(1, DateTime(2026, 9, 30));
      expect(buckets, hasLength(1));
      expect(buckets.single.avgRttMs, 12.5);
    });

    test('recovers orphaned tmp files on init', () async {
      String dayKey(DateTime t) =>
          '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      // Dates relative to now: fixed dates rot as the wall clock moves
      // (prune would eat them).
      final now = DateTime.now().toUtc();
      final orphanDay = dayKey(now.subtract(const Duration(days: 1)));
      final bothDay = dayKey(now.subtract(const Duration(days: 2)));
      final dir = await _tempDir();
      final hist = Directory('${dir.path}/VeloceNet-Studio/history');
      await hist.create(recursive: true);
      // Crash between temp-write and rename: only the tmp exists.
      await File('${hist.path}/$orphanDay.json.tmp').writeAsString('{"1": []}');
      // Stale partial next to a complete day file: tmp must go.
      await File('${hist.path}/$bothDay.json').writeAsString('{}');
      await File('${hist.path}/$bothDay.json.tmp').writeAsString('{"1": []}');
      final svc = UptimeHistoryService(directoryProvider: () async => dir);
      await svc.init();
      expect(await File('${hist.path}/$orphanDay.json').exists(), isTrue);
      expect(await File('${hist.path}/$orphanDay.json.tmp').exists(), isFalse);
      expect(await File('${hist.path}/$bothDay.json.tmp').exists(), isFalse);
      expect(await File('${hist.path}/$bothDay.json').exists(), isTrue);
    });

    test('outage spans split across data gaps', () {
      List<MinuteBucket> buckets(List<int> minutes, int status) => [
            for (final m in minutes)
              MinuteBucket(
                  minute: m, avgRttMs: 0, lossPct: 100, worstStatus: status),
          ];
      // Two bad minutes 3 hours apart: two spans, not one mega-outage.
      final spans = findOutages([
        ...buckets([1000, 1001], TargetStatus.offline.index),
        ...buckets([1181, 1182], TargetStatus.offline.index),
      ]);
      expect(spans, hasLength(2));
      expect(spans[0].duration, const Duration(minutes: 2));
      // Adjacent bad minutes still merge.
      final merged =
          findOutages(buckets([1000, 1001, 1002], TargetStatus.degraded.index));
      expect(merged, hasLength(1));
      expect(merged.single.duration, const Duration(minutes: 3));
    });

    test('prunes files older than retention', () async {
      final dir = await _tempDir();
      final old = File('${dir.path}/VeloceNet-Studio/history/2020-01-01.json');
      await old.create(recursive: true);
      await old.writeAsString('{}');
      final svc = UptimeHistoryService(directoryProvider: () async => dir);
      await svc.init();
      expect(await old.exists(), isFalse);
    });
  });
}

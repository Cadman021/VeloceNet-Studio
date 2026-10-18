import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/ping_metric.dart';

/// One finalized minute bucket for a single target.
class MinuteBucket {
  /// Minute epoch (milliseconds ~/ 60000).
  final int minute;
  final double avgRttMs;
  final double lossPct;
  final int worstStatus; // TargetStatus.index

  const MinuteBucket({
    required this.minute,
    required this.avgRttMs,
    required this.lossPct,
    required this.worstStatus,
  });

  Map<String, dynamic> toJson() => {
        't': minute,
        'avg': (avgRttMs * 10).round() / 10, // 0.1ms resolution on disk
        'loss': (lossPct * 10).round() / 10,
        's': worstStatus,
      };

  factory MinuteBucket.fromJson(Map<String, dynamic> json) {
    return MinuteBucket(
      minute: (json['t'] as num).toInt(),
      avgRttMs: (json['avg'] as num?)?.toDouble() ?? 0.0,
      lossPct: (json['loss'] as num?)?.toDouble() ?? 0.0,
      worstStatus: (json['s'] as num?)?.toInt() ?? TargetStatus.pending.index,
    );
  }
}

/// Lifetime probe counters snapshot for delta computation.
class _Counters {
  final int sent;
  final int received;
  const _Counters(this.sent, this.received);
}

/// Mutable per-minute accumulator (pure logic — unit tested).
class MinuteAccumulator {
  int count = 0;
  double sumRtt = 0;
  int received = 0;
  int lost = 0;
  int worstStatus = TargetStatus.pending.index;

  void add(
      {required bool success, required double rttMs, required int status}) {
    count++;
    if (success) {
      received++;
      sumRtt += rttMs;
    } else {
      lost++;
    }
    if (status > worstStatus) worstStatus = status;
  }

  MinuteBucket finalize(int minute) {
    return MinuteBucket(
      minute: minute,
      avgRttMs: received > 0 ? sumRtt / received : 0.0,
      lossPct: count > 0 ? lost / count * 100.0 : 0.0,
      worstStatus: worstStatus,
    );
  }
}

/// One continuous non-online span for the outage report.
class OutageSpan {
  final DateTime start;
  final DateTime end;
  final int worstStatus;
  const OutageSpan(
      {required this.start, required this.end, required this.worstStatus});

  Duration get duration => end.difference(start);
}

/// Finds non-online spans in a minute-ordered bucket list. Pure, tested.
///
/// Data gaps (app was closed: no buckets at all) SPLIT spans — the minutes
/// in between are unknown, not outage. A gap longer than [maxGap] between
/// two consecutive bad minutes closes the span before the gap.
List<OutageSpan> findOutages(
  List<MinuteBucket> buckets, {
  Duration maxGap = const Duration(minutes: 10),
}) {
  final out = <OutageSpan>[];
  DateTime? spanStart;
  int worst = TargetStatus.pending.index;
  DateTime? lastMinute;

  void close() {
    final start = spanStart;
    final last = lastMinute;
    // Both are always set together (a span opens and stamps the minute in
    // the same iteration), so reaching here with either null is impossible.
    if (start != null && last != null) {
      out.add(OutageSpan(
        start: start,
        end: last.add(const Duration(minutes: 1)),
        worstStatus: worst,
      ));
      spanStart = null;
    }
  }

  for (final b in buckets) {
    // Minute keys are absolute epoch minutes; reconstructing without
    // isUtc keeps outage clock times in the user's local timezone.
    final t = DateTime.fromMillisecondsSinceEpoch(b.minute * 60000);
    if (spanStart != null &&
        lastMinute != null &&
        t.difference(lastMinute) > maxGap + const Duration(minutes: 1)) {
      // Unknown territory in between: end the span here rather than
      // claiming a continuous outage across hours the app never observed.
      close();
      worst = TargetStatus.pending.index;
    }
    final bad = b.worstStatus != TargetStatus.online.index;
    if (bad) {
      spanStart ??= t;
      if (b.worstStatus > worst) worst = b.worstStatus;
    } else {
      close();
      worst = TargetStatus.pending.index;
    }
    lastMinute = t;
  }
  close();
  return out;
}

/// Persists per-minute rollups as append-only JSONL logs, one per LOCAL day:
/// `<support>/VeloceNet-Studio/history/YYYY-MM-DD.jsonl`, each line
/// `{id, t, avg, loss, s}`. Retention is 7 days, pruned on init.
///
/// Why append-only: the previous version rewrote the whole day's map on
/// every minute rollover (O(n) encode + delete + rename per minute). At the
/// end of a day that is thousands of buckets rewritten 1440 times. Now a
/// flush costs one buffered append, and a torn last line from a crash is
/// skipped by the reader.
///
/// Legacy `<day>.json` map files are still read (and never rewritten), so
/// upgrading users keep their history.
class UptimeHistoryService {
  static const int retentionDays = 7;

  final Future<Directory> Function()? _directoryProvider;
  Directory? _dir;
  final Map<int, MinuteAccumulator> _open = {};
  int _openMinute = -1;
  final Map<String, Map<int, List<MinuteBucket>>> _dayCache = {};
  bool _ready = false;

  /// Injectable directory for tests (`Directory.systemTemp` subtree).
  UptimeHistoryService({Future<Directory> Function()? directoryProvider})
      : _directoryProvider = directoryProvider;

  bool get isReady => _ready;

  Future<void> init() async {
    try {
      final provider = _directoryProvider;
      final base = provider != null
          ? await provider()
          : await getApplicationSupportDirectory();
      _dir = Directory('${base.path}${Platform.pathSeparator}VeloceNet-Studio'
          '${Platform.pathSeparator}history');
      await _dir!.create(recursive: true);
      await _recoverOrphanedTmps();
      await _pruneOld();
      _ready = true;
    } catch (e) {
      debugPrint('Uptime history unavailable: $e');
    }
  }

  String _dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  // Last seen lifetime counters per target: frames carry cumulative
  // counters, so only the DELTA since the previous frame represents new
  // probes. Sampling every frame regardless of probe rate over-counts slow
  // targets (5s interval sampled 10x) and drops fast ones (200ms).
  final Map<int, _Counters> _prevCounts = {};

  /// Records one metrics frame into the current minute bucket, rolling the
  /// minute over (and flushing) when the clock advances. No-op until init.
  Future<void> recordFrame(Map<int, PingMetric> metrics,
      {DateTime? now}) async {
    if (!_ready) return;
    // Epoch minutes are timezone-independent; converting to local here only
    // decides which LOCAL day file the minute belongs to when it flushes.
    final minute = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 60000;
    if (_openMinute != -1 && minute != _openMinute) {
      await _flushMinute(_openMinute);
      _open.clear();
    }
    _openMinute = minute;
    // Drop bookkeeping for removed targets.
    _prevCounts.removeWhere((id, _) => !metrics.containsKey(id));
    for (final m in metrics.values) {
      final prev = _prevCounts[m.id];
      _prevCounts[m.id] = _Counters(m.sentCount, m.receivedCount);
      // No new probes since last frame (or pre-first-probe pending with
      // zero counters): record nothing instead of a phantom loss.
      final dSent = m.sentCount - (prev?.sent ?? 0);
      if (dSent <= 0) continue;
      final dRecv = (m.receivedCount - (prev?.received ?? 0)).clamp(0, dSent);
      final acc = _open.putIfAbsent(m.id, () => MinuteAccumulator());
      // Replay capped: after a long gap (suspend/resume) the delta could be
      // huge; the window only holds recent history anyway.
      final replay = dSent > 600 ? 600 : dSent;
      final recvReplay = (dRecv * replay) ~/ dSent;
      for (int i = 0; i < replay; i++) {
        final ok = i < recvReplay;
        acc.add(
          success: ok,
          rttMs: ok ? m.lastRttMs : -1.0,
          status: m.status.index,
        );
      }
    }
  }

  Future<void> flush() async {
    if (!_ready || _openMinute == -1) return;
    await _flushMinute(_openMinute);
    _open.clear();
    _openMinute = -1;
  }

  Future<void> _flushMinute(int minute) async {
    if (_open.isEmpty) return;
    // Local midnight (not UTC) defines the day file boundary.
    final day = _dayKey(DateTime.fromMillisecondsSinceEpoch(minute * 60000));
    final table = await _loadDay(day);
    final entries = <Map<String, dynamic>>[];
    _open.forEach((id, acc) {
      final bucket = acc.finalize(minute);
      table.putIfAbsent(id, () => []).add(bucket);
      entries.add({'id': id, ...bucket.toJson()});
    });
    await _appendBuckets(day, entries);
  }

  /// Recovers orphaned `.tmp` files left by a crash between temp-write and
  /// rename: if the day file is missing, the tmp holds the only copy and is
  /// promoted; if both exist, the tmp is a stale partial and is dropped.
  /// Runs once at init (best-effort, never throws).
  Future<void> _recoverOrphanedTmps() async {
    try {
      await for (final e in _dir!.list()) {
        if (e is! File || !e.path.endsWith('.json.tmp')) continue;
        final targetPath = e.path.substring(0, e.path.length - '.tmp'.length);
        final target = File(targetPath);
        if (await target.exists()) {
          await e.delete();
        } else {
          try {
            await e.rename(targetPath);
          } catch (_) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('Uptime history tmp recovery failed: $e');
    }
  }

  Future<Map<int, List<MinuteBucket>>> _loadDay(String day) async {
    final cached = _dayCache[day];
    if (cached != null) return cached;
    final table = <int, List<MinuteBucket>>{};
    final sep = Platform.pathSeparator;
    // Legacy format: one `{targetId: [buckets]}` map per day. Read-only;
    // new data always goes to the JSONL log.
    try {
      final file = File('${_dir!.path}$sep$day.json');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final id = int.tryParse('$k');
            if (id == null || v is! List) return;
            table[id] = v
                .whereType<Map<String, dynamic>>()
                .map(MinuteBucket.fromJson)
                .toList();
          });
        }
      }
    } catch (e) {
      debugPrint('Uptime history read failed ($day): $e');
    }
    // Append-only log written by this version. A crash can leave a torn
    // last line: skip anything that does not parse instead of dropping the
    // whole day.
    try {
      final log = File('${_dir!.path}$sep$day.jsonl');
      if (await log.exists()) {
        final lines = await log.readAsLines();
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final decoded = jsonDecode(line);
            if (decoded is! Map<String, dynamic>) continue;
            final id = (decoded['id'] as num?)?.toInt();
            if (id == null) continue;
            table.putIfAbsent(id, () => []).add(MinuteBucket.fromJson(decoded));
          } catch (_) {
            // Torn/foreign line; ignore it.
          }
        }
      }
    } catch (e) {
      debugPrint('Uptime history log read failed ($day): $e');
    }
    _dayCache[day] = table;
    return table;
  }

  /// Appends finalized buckets as JSONL. A leading newline guarantees the
  /// new record starts on a fresh line even if a previous crash left a torn
  /// one; blank/partial lines are ignored by [_loadDay].
  Future<void> _appendBuckets(
      String day, List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty) return;
    try {
      final file = File('${_dir!.path}${Platform.pathSeparator}$day.jsonl');
      final buffer = StringBuffer('\n');
      for (final entry in entries) {
        buffer.writeln(jsonEncode(entry));
      }
      await file.writeAsString(buffer.toString(),
          mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('Uptime history append failed ($day): $e');
    }
  }

  /// Buckets for one target on one local day (empty when no data).
  Future<List<MinuteBucket>> bucketsFor(int targetId, DateTime day) async {
    if (!_ready) return const [];
    final table = await _loadDay(_dayKey(day));
    final list = List<MinuteBucket>.from(table[targetId] ?? const []);
    list.sort((a, b) => a.minute.compareTo(b.minute));
    return list;
  }

  Future<void> _pruneOld() async {
    try {
      final cutoff =
          DateTime.now().subtract(const Duration(days: retentionDays));
      await for (final e in _dir!.list()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        String dayPart;
        if (name.endsWith('.jsonl')) {
          dayPart = name.replaceSuffix('.jsonl');
        } else if (name.endsWith('.json')) {
          dayPart = name.replaceSuffix('.json');
        } else {
          continue;
        }
        final day = DateTime.tryParse(dayPart);
        if (day != null && day.isBefore(cutoff)) {
          await e.delete();
        }
      }
    } catch (e) {
      debugPrint('Uptime history prune failed: $e');
    }
  }
}

extension on String {
  String replaceSuffix(String suffix) =>
      endsWith(suffix) ? substring(0, length - suffix.length) : this;
}

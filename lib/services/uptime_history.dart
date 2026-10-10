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

/// Mutable per-minute accumulator (pure logic — unit tested).
class MinuteAccumulator {
  int count = 0;
  double sumRtt = 0;
  int received = 0;
  int lost = 0;
  int worstStatus = TargetStatus.pending.index;

  void add({required bool success, required double rttMs, required int status}) {
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
List<OutageSpan> findOutages(List<MinuteBucket> buckets) {
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
    final t =
        DateTime.fromMillisecondsSinceEpoch(b.minute * 60000, isUtc: true);
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

/// Persists per-minute rollups as one JSON file per UTC day:
/// `<support>/VeloceNet-Studio/history/YYYY-MM-DD.json`, each a
/// `{targetId: [buckets]}` map. Retention is 7 days, pruned on init.
///
/// Design note (deliberate, not laziness): this lives in Dart with plain
/// JSON instead of rusqlite — zero native build deps on all three release
/// platforms, trivially testable, and ~600KB/day at 10 targets is nothing.
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
      _dir = Directory(
          '${base.path}${Platform.pathSeparator}VeloceNet-Studio'
          '${Platform.pathSeparator}history');
      await _dir!.create(recursive: true);
      await _pruneOld();
      _ready = true;
    } catch (e) {
      debugPrint('Uptime history unavailable: $e');
    }
  }

  String _dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// Records one metrics frame into the current minute bucket, rolling the
  /// minute over (and flushing) when the clock advances. No-op until init.
  Future<void> recordFrame(Map<int, PingMetric> metrics, {DateTime? now}) async {
    if (!_ready) return;
    final minute = ((now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 60000);
    if (_openMinute != -1 && minute != _openMinute) {
      await _flushMinute(_openMinute);
      _open.clear();
    }
    _openMinute = minute;
    for (final m in metrics.values) {
      _open
          .putIfAbsent(m.id, () => MinuteAccumulator())
          .add(success: m.lastRttMs > 0, rttMs: m.lastRttMs, status: m.status.index);
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
    final day = _dayKey(
        DateTime.fromMillisecondsSinceEpoch(minute * 60000, isUtc: true));
    final table = await _loadDay(day);
    _open.forEach((id, acc) {
      table.putIfAbsent(id, () => []).add(acc.finalize(minute));
    });
    await _saveDay(day, table);
  }

  Future<Map<int, List<MinuteBucket>>> _loadDay(String day) async {
    final cached = _dayCache[day];
    if (cached != null) return cached;
    final table = <int, List<MinuteBucket>>{};
    try {
      final file = File('${_dir!.path}${Platform.pathSeparator}$day.json');
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
    _dayCache[day] = table;
    return table;
  }

  Future<void> _saveDay(
      String day, Map<int, List<MinuteBucket>> table) async {
    // Atomic write: a crash/kill mid-flush must never leave a truncated
    // day file behind (that would silently erase the whole day). Write to
    // a temp sibling, then move it over the target.
    try {
      final dir = _dir!.path;
      final target =
          File('$dir${Platform.pathSeparator}$day.json');
      final tmp =
          File('$dir${Platform.pathSeparator}$day.json.tmp');
      final encoded = table.map((k, v) =>
          MapEntry('$k', v.map((b) => b.toJson()).toList()));
      await tmp.writeAsString(jsonEncode(encoded), flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(target.path);
    } catch (e) {
      debugPrint('Uptime history write failed ($day): $e');
    }
  }

  /// Buckets for one target on one UTC day (empty when no data).
  Future<List<MinuteBucket>> bucketsFor(int targetId, DateTime day) async {
    if (!_ready) return const [];
    final table = await _loadDay(_dayKey(day.toUtc()));
    final list = List<MinuteBucket>.from(table[targetId] ?? const []);
    list.sort((a, b) => a.minute.compareTo(b.minute));
    return list;
  }

  Future<void> _pruneOld() async {
    try {
      final cutoff = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: retentionDays));
      await for (final e in _dir!.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        final day = DateTime.tryParse(name.replaceSuffix('.json'));
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

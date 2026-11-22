import 'package:material_ui/material_ui.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/ping_metric.dart';
import '../../../models/ping_target.dart';
import '../../../services/uptime_history.dart';

/// History for one target: a single local day (hourly bars), or the last
/// 7/30 days (one bar per day) with window uptime/SLA and outage reports.
/// Data comes from the local rollup store (local days).
class UptimeHistoryDialog extends StatefulWidget {
  final PingTarget target;
  final UptimeHistoryService history;

  const UptimeHistoryDialog({
    super.key,
    required this.target,
    required this.history,
  });

  static Future<void> show(
    BuildContext context,
    PingTarget target,
    UptimeHistoryService history,
  ) {
    return showDialog(
      context: context,
      builder: (ctx) => UptimeHistoryDialog(target: target, history: history),
    );
  }

  @override
  State<UptimeHistoryDialog> createState() => _UptimeHistoryDialogState();
}

enum _HistoryMode { day, week, month }

extension on _HistoryMode {
  int get days => switch (this) {
        _HistoryMode.day => 1,
        _HistoryMode.week => 7,
        _HistoryMode.month => 30,
      };
}

class _UptimeHistoryDialogState extends State<UptimeHistoryDialog> {
  _HistoryMode _mode = _HistoryMode.day;

  /// 0 = today (local), 1 = yesterday, … up to retention - 1. Used by the
  /// day view and also set when a range bar is tapped.
  int _dayOffset = 0;
  late Future<_HistoryPayload> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  DateTime get _day => DateTime.now().subtract(Duration(days: _dayOffset));

  String _dayLabel(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  void _shiftDay(int delta) {
    final next =
        (_dayOffset + delta).clamp(0, UptimeHistoryService.retentionDays - 1);
    if (next == _dayOffset) return;
    setState(() {
      _dayOffset = next;
      _future = _load();
    });
  }

  void _setMode(_HistoryMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _future = _load();
    });
  }

  void _openDay(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);
    final offset = today.difference(target).inDays;
    if (offset < 0 || offset >= UptimeHistoryService.retentionDays) return;
    setState(() {
      _mode = _HistoryMode.day;
      _dayOffset = offset;
      _future = _load();
    });
  }

  Future<_HistoryPayload> _load() async {
    if (_mode == _HistoryMode.day) {
      final day = _day;
      final buckets = await widget.history.bucketsFor(widget.target.id, day);
      buckets.sort((a, b) => a.minute.compareTo(b.minute));
      return _HistoryPayload(day: _DayView.fromBuckets(buckets, day));
    }
    final range = await widget.history.rangeSummaries(
      widget.target.id,
      days: _mode.days,
    );
    return _HistoryPayload(range: range);
  }

  Color _statusColor(int status, BuildContext context) {
    switch (TargetStatus.values[status.clamp(0, 3)]) {
      case TargetStatus.online:
        return AppColors.latencyFast;
      case TargetStatus.degraded:
        return AppColors.latencyModerate;
      case TargetStatus.offline:
        return AppColors.latencyCritical;
      case TargetStatus.pending:
        return context.textMutedColor;
    }
  }

  static Color _barColor(int worstBad, BuildContext context) {
    if (worstBad == TargetStatus.offline.index) {
      return AppColors.latencyCritical;
    }
    if (worstBad == TargetStatus.degraded.index) {
      return AppColors.latencyModerate;
    }
    return AppColors.latencyFast;
  }

  String _clock(DateTime t, AppStrings strings) {
    String two(int n) => n.toString().padLeft(2, '0');
    // Local wall-clock reads better than UTC in a dialog; the buckets are
    // minute-aligned so the offset shifting is exact.
    final local = t.toLocal();
    return '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Dialog(
      child: Container(
        width: 640,
        constraints: const BoxConstraints(maxHeight: 620),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history_rounded,
                    color: AppColors.primary, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.target.name} — ${strings.get('history')}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimaryColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close,
                      size: 18, color: context.textMutedColor),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<_HistoryMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
              ),
              segments: [
                ButtonSegment(
                    value: _HistoryMode.day,
                    label: Text(strings.get('historyDay'))),
                ButtonSegment(
                    value: _HistoryMode.week,
                    label: Text(strings.get('history7d'))),
                ButtonSegment(
                    value: _HistoryMode.month,
                    label: Text(strings.get('history30d'))),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => _setMode(s.first),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: FutureBuilder<_HistoryPayload>(
                future: _future,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  final payload = snap.data!;
                  final day = payload.day;
                  if (day != null) {
                    if (day.hours.every((h) => h == null)) {
                      return _NoData(strings: strings);
                    }
                    return _buildDay(context, strings, day);
                  }
                  final range = payload.range ?? const <DaySummary>[];
                  if (range.every((d) => !d.hasData)) {
                    return _NoData(strings: strings);
                  }
                  return _buildRange(context, strings, range);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDay(BuildContext context, AppStrings strings, _DayView view) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded, size: 20),
                color: _dayOffset >= UptimeHistoryService.retentionDays - 1
                    ? context.textMutedColor.withValues(alpha: 0.3)
                    : context.textSecondaryColor,
                tooltip: '−1',
                onPressed: () => _shiftDay(1),
              ),
              Text(
                _dayLabel(_day),
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded, size: 20),
                color: _dayOffset <= 0
                    ? context.textMutedColor.withValues(alpha: 0.3)
                    : context.textSecondaryColor,
                tooltip: '+1',
                onPressed: () => _shiftDay(-1),
              ),
              const Spacer(),
              Text(
                '${strings.get('uptime24h')}: ${view.uptimePct.toStringAsFixed(1)}%',
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 56,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int h = 0; h < 24; h++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.5),
                      child: Tooltip(
                        message: view.hours[h] == null
                            ? '—'
                            : '${_clock(view.hourStart(h), strings)} • ${view.hours[h]!.onlineMinutes}/60',
                        child: Container(
                          height: view.hours[h] == null
                              ? 6
                              : 14 + 42 * (view.hours[h]!.onlineMinutes / 60),
                          decoration: BoxDecoration(
                            color: view.hours[h] == null
                                ? context.borderColor
                                : _barColor(view.hours[h]!.worstBad, context),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _outageHeader(strings, view.outages.length),
          const SizedBox(height: 8),
          if (view.outages.isEmpty)
            _dash(context)
          else
            for (final o in view.outages)
              _OutageRow(
                day: _day,
                span: o,
                clock: (t) => _clock(t, strings),
                duration: _formatDuration(o.duration),
                statusColor: _statusColor(o.worstStatus, context),
              ),
        ],
      ),
    );
  }

  Widget _buildRange(
      BuildContext context, AppStrings strings, List<DaySummary> range) {
    final dataDays = range.where((d) => d.hasData).toList();
    final totalOnline =
        dataDays.fold<int>(0, (sum, d) => sum + d.onlineMinutes);
    final totalData = dataDays.fold<int>(0, (sum, d) => sum + d.dataMinutes);
    final uptime = totalData == 0 ? 0.0 : totalOnline / totalData * 100.0;
    final downtime =
        range.fold<Duration>(Duration.zero, (sum, d) => sum + d.downtime);
    final outages = <_DatedOutage>[
      for (final d in range)
        for (final o in d.outages) _DatedOutage(day: d.day, span: o),
    ]..sort((a, b) => a.span.start.compareTo(b.span.start));

    final windowStart = range.isNotEmpty ? range.first.day : DateTime.now();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${_dayLabel(windowStart)} → ${_dayLabel(range.isEmpty ? windowStart : range.last.day)}',
                style: TextStyle(
                  color: context.textSecondaryColor,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
              const Spacer(),
              Text(
                '${strings.get('rangeUptime')}: ${uptime.toStringAsFixed(1)}%',
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 14),
              Text(
                '${strings.get('totalDowntime')}: ${_formatDuration(downtime)}',
                style: TextStyle(
                  color: context.textMutedColor,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 68,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in range)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Tooltip(
                        message: d.hasData
                            ? '${_dayLabel(d.day)} • ${d.uptimePct.toStringAsFixed(1)}% • ${d.onlineMinutes}/${d.dataMinutes} min'
                            : '${_dayLabel(d.day)} • —',
                        child: InkWell(
                          onTap: d.hasData ? () => _openDay(d.day) : null,
                          borderRadius: BorderRadius.circular(3),
                          child: Container(
                            height:
                                d.hasData ? 14 + 54 * (d.uptimePct / 100) : 6,
                            decoration: BoxDecoration(
                              color: d.hasData
                                  ? _barColor(d.worstBad, context)
                                  : context.borderColor,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                _dayLabel(range.first.day),
                style: TextStyle(
                    color: context.textMutedColor,
                    fontSize: 9,
                    fontFamily: 'monospace'),
              ),
              const Spacer(),
              Text(
                strings.get('dailyUptime'),
                style: TextStyle(color: context.textMutedColor, fontSize: 9),
              ),
              const Spacer(),
              Text(
                _dayLabel(range.last.day),
                style: TextStyle(
                    color: context.textMutedColor,
                    fontSize: 9,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _outageHeader(strings, outages.length),
          const SizedBox(height: 8),
          if (outages.isEmpty)
            _dash(context)
          else
            for (final o in outages)
              _OutageRow(
                day: o.day,
                span: o.span,
                clock: (t) => _clock(t, strings),
                duration: _formatDuration(o.span.duration),
                statusColor: _statusColor(o.span.worstStatus, context),
              ),
        ],
      ),
    );
  }

  Widget _outageHeader(AppStrings strings, int count) {
    return Text(
      '${strings.get('outages')} ($count)',
      style: TextStyle(
        color: context.textPrimaryColor,
        fontSize: 13,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _dash(BuildContext context) => Text(
        '—',
        style: TextStyle(color: context.textMutedColor, fontSize: 12),
      );

  String _formatDuration(Duration d) {
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }
}

class _NoData extends StatelessWidget {
  final AppStrings strings;
  const _NoData({required this.strings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(
          strings.get('noHistory'),
          style: TextStyle(color: context.textMutedColor, fontSize: 13),
        ),
      ),
    );
  }
}

class _HistoryPayload {
  final _DayView? day;
  final List<DaySummary>? range;

  const _HistoryPayload({this.day, this.range});
}

class _DatedOutage {
  final DateTime day;
  final OutageSpan span;
  const _DatedOutage({required this.day, required this.span});
}

class _OutageRow extends StatelessWidget {
  final DateTime day;
  final OutageSpan span;
  final String Function(DateTime) clock;
  final String duration;
  final Color statusColor;

  const _OutageRow({
    required this.day,
    required this.span,
    required this.clock,
    required this.duration,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${day.year}-${two(day.month)}-${two(day.day)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            date,
            style: TextStyle(
              color: context.textMutedColor,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${clock(span.start)} → ${clock(span.end)}',
              style: TextStyle(
                color: context.textSecondaryColor,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Text(
            duration,
            style: TextStyle(
              color: context.textMutedColor,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _HourSummary {
  int onlineMinutes = 0;
  int dataMinutes = 0;

  /// Worst *bad* status seen this hour (degraded/offline index), or -1.
  int worstBad = -1;
}

class _DayView {
  /// 24 hourly summaries, oldest hour first; null = no data that hour.
  final List<_HourSummary?> hours;
  final List<OutageSpan> outages;
  final double uptimePct;
  final DateTime windowStart;

  _DayView({
    required this.hours,
    required this.outages,
    required this.uptimePct,
    required this.windowStart,
  });
  DateTime hourStart(int h) =>
      DateTime(windowStart.year, windowStart.month, windowStart.day, h);

  factory _DayView.fromBuckets(List<MinuteBucket> buckets, DateTime day) {
    // Local midnight: the day file and its 24 hourly bars follow the
    // user's wall clock, not UTC.
    final windowStart = DateTime(day.year, day.month, day.day);
    final hours = List<_HourSummary?>.filled(24, null);
    int online = 0;
    int total = 0;
    for (final b in buckets) {
      final t = DateTime.fromMillisecondsSinceEpoch(b.minute * 60000);
      // t.hour (not a duration diff) keeps the bars aligned on 23/25-hour
      // DST transition days.
      final h = t.hour;
      if (h < 0 || h >= 24) continue;
      total++;
      final s = hours[h] ??= _HourSummary();
      s.dataMinutes++;
      if (b.worstStatus == TargetStatus.online.index) {
        online++;
        s.onlineMinutes++;
      } else if (b.worstStatus == TargetStatus.degraded.index ||
          b.worstStatus == TargetStatus.offline.index) {
        if (b.worstStatus > s.worstBad) s.worstBad = b.worstStatus;
      }
    }
    return _DayView(
      hours: hours,
      outages: findOutages(buckets),
      uptimePct: total > 0 ? online / total * 100.0 : 0.0,
      windowStart: windowStart,
    );
  }
}

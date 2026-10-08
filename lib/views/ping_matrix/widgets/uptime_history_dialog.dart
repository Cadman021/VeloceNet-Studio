import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/ping_metric.dart';
import '../../../models/ping_target.dart';
import '../../../services/uptime_history.dart';

/// 24-hour history for one target: hourly status bars, uptime % and the
/// outage list. Data comes from the local rollup store (UTC days).
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
      builder: (ctx) =>
          UptimeHistoryDialog(target: target, history: history),
    );
  }

  @override
  State<UptimeHistoryDialog> createState() => _UptimeHistoryDialogState();
}

class _UptimeHistoryDialogState extends State<UptimeHistoryDialog> {
  late final Future<_DayView> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_DayView> _load() async {
    final now = DateTime.now().toUtc();
    final all = <MinuteBucket>[];
    for (int d = 0; d < 2; d++) {
      all.addAll(await widget.history.bucketsFor(
        widget.target.id,
        now.subtract(Duration(days: d)),
      ));
    }
    all.sort((a, b) => a.minute.compareTo(b.minute));
    final cutoff = now.millisecondsSinceEpoch ~/ 60000 - 24 * 60;
    final window = all.where((b) => b.minute >= cutoff).toList();
    return _DayView.fromBuckets(window);
  }

  Color _hourColor(_HourSummary s, BuildContext context) {
    if (s.worstBad == TargetStatus.offline.index) {
      return AppColors.latencyCritical;
    }
    if (s.worstBad == TargetStatus.degraded.index) {
      return AppColors.latencyModerate;
    }
    return AppColors.latencyFast;
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
        width: 560,
        constraints: const BoxConstraints(maxHeight: 560),
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
                    '${widget.target.name} — ${strings.get('last24h')}',
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
            const SizedBox(height: 12),
            Flexible(
              child: FutureBuilder<_DayView>(
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
                  final view = snap.data!;
                  if (view.hours.every((h) => h == null)) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          strings.get('noHistory'),
                          style: TextStyle(
                              color: context.textMutedColor, fontSize: 13),
                        ),
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
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
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 1.5),
                                    child: Tooltip(
                                      message: view.hours[h] == null
                                          ? '—'
                                          : '${_clock(view.hourStart(h), strings)} • ${view.hours[h]!.onlineMinutes}/60',
                                      child: Container(
                                        height: view.hours[h] == null
                                            ? 6
                                            : 14 +
                                                42 *
                                                    (view.hours[h]!
                                                            .onlineMinutes /
                                                        60),
                                        decoration: BoxDecoration(
                                          color: view.hours[h] == null
                                              ? context.borderColor
                                              : _hourColor(
                                                  view.hours[h]!, context),
                                          borderRadius:
                                              BorderRadius.circular(3),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '${strings.get('outages')} (${view.outages.length})',
                          style: TextStyle(
                            color: context.textPrimaryColor,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (view.outages.isEmpty)
                          Text(
                            '—',
                            style: TextStyle(
                                color: context.textMutedColor, fontSize: 12),
                          ),
                        for (final o in view.outages)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _statusColor(o.worstStatus, context),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${_clock(o.start, strings)} → ${_clock(o.end, strings)}',
                                    style: TextStyle(
                                      color: context.textSecondaryColor,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                Text(
                                  _formatDuration(o.duration),
                                  style: TextStyle(
                                    color: context.textMutedColor,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
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
      windowStart.add(Duration(hours: h));

  factory _DayView.fromBuckets(List<MinuteBucket> buckets) {
    final now = DateTime.now().toUtc();
    final windowStart = DateTime.utc(now.year, now.month, now.day, now.hour)
        .subtract(const Duration(hours: 23));
    final hours = List<_HourSummary?>.filled(24, null);
    int online = 0;
    int total = 0;
    for (final b in buckets) {
      final t =
          DateTime.fromMillisecondsSinceEpoch(b.minute * 60000, isUtc: true);
      final h = t.difference(windowStart).inHours;
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

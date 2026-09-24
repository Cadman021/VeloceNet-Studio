import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/alert_event.dart';
import '../../../models/ping_metric.dart';
import '../../../state/alert_log.dart';

/// Alert history dialog: newest-first status transitions.
class AlertLogDialog extends StatelessWidget {
  final AlertLog log;

  const AlertLogDialog({super.key, required this.log});

  static Future<void> show(BuildContext context, AlertLog log) {
    log.markAllRead();
    return showDialog(
      context: context,
      builder: (ctx) => AlertLogDialog(log: log),
    );
  }

  String _statusLabel(AppStrings strings, TargetStatus s) {
    switch (s) {
      case TargetStatus.online:
        return strings.get('statusOnline');
      case TargetStatus.degraded:
        return strings.get('statusDegraded');
      case TargetStatus.offline:
        return strings.get('statusOffline');
      case TargetStatus.pending:
        return strings.get('statusPending');
    }
  }

  Color _severityColor(AlertEvent e) {
    switch (e.severity) {
      case AlertSeverity.critical:
        return AppColors.latencyCritical;
      case AlertSeverity.warning:
        return AppColors.latencyModerate;
      case AlertSeverity.info:
        return AppColors.latencyFast;
    }
  }

  String _clock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Dialog(
      child: Container(
        width: 560,
        constraints: const BoxConstraints(maxHeight: 520),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_outlined,
                    color: AppColors.primary, size: 22),
                const SizedBox(width: 8),
                Text(
                  strings.get('alerts'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimaryColor,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: log.clear,
                  child: Text(strings.get('clearAll')),
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
              child: AnimatedBuilder(
                animation: log,
                builder: (context, _) {
                  if (log.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          strings.get('noAlerts'),
                          style: TextStyle(
                              color: context.textMutedColor, fontSize: 13),
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: log.events.length,
                    separatorBuilder: (_, __) => Divider(
                        color: context.borderColor, height: 1),
                    itemBuilder: (context, i) =>
                        _row(context, strings, log.events[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, AppStrings strings, AlertEvent e) {
    final color = _severityColor(e);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.targetName,
                  style: TextStyle(
                    color: context.textPrimaryColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${_statusLabel(strings, e.from)} → ${_statusLabel(strings, e.to)}'
                  '${e.rttMs > 0 ? ' • ${e.rttMs.toStringAsFixed(1)} ms' : ''}'
                  '${e.lossRate > 0 ? ' • loss ${e.lossRate.toStringAsFixed(1)}%' : ''}',
                  style: TextStyle(
                      color: context.textSecondaryColor, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _clock(e.timestamp),
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

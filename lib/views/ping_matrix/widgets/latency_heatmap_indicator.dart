import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/ping_metric.dart';

class LatencyHeatmapIndicator extends StatelessWidget {
  final double latencyMs;
  final double lossRate;
  final TargetStatus status;

  const LatencyHeatmapIndicator({
    super.key,
    required this.latencyMs,
    required this.lossRate,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final rtt = latencyMs.toStringAsFixed(1);
    final Color color = status == TargetStatus.pending
        ? AppColors.pending
        : AppColors.getLatencyColor(latencyMs, lossRate);

    final String text = status == TargetStatus.pending
        ? strings.get('heatmapPending')
        : latencyMs < 0
            ? strings.get('heatmapLoss')
            : '$rtt ms';

    final statusKey = switch (status) {
      TargetStatus.pending => 'statusPending',
      TargetStatus.online => 'statusOnline',
      TargetStatus.degraded => 'statusDegraded',
      TargetStatus.offline => 'statusOffline',
    };
    final semanticsKey = status == TargetStatus.pending
        ? 'heatmapPendingSemantics'
        : latencyMs < 0
            ? 'heatmapLossSemantics'
            : 'heatmapRttSemantics';
    final label = strings
        .get(semanticsKey)
        .replaceAll('{status}', strings.get(statusKey))
        .replaceAll('{rtt}', rtt);

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.25),
              blurRadius: 8,
              spreadRadius: -2,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/ping_metric.dart';
import '../../../models/ping_target.dart';
import 'latency_heatmap_indicator.dart';
import 'latency_sparkline.dart';

class TargetCard extends StatelessWidget {
  final PingTarget target;
  final PingMetric? metric;
  final VoidCallback onDeletePressed;

  const TargetCard({
    super.key,
    required this.target,
    required this.metric,
    required this.onDeletePressed,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final m = metric ??
        PingMetric.initial(
          target.id,
          target.name,
          target.host,
          target.port,
          target.protocol.label,
        );

    final statusColor = AppColors.getLatencyColor(m.lastRttMs, m.lossRate);

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: m.status == TargetStatus.offline
              ? AppColors.latencyCritical.withValues(alpha: 0.5)
              : context.borderColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor.withValues(alpha: 0.04),
            blurRadius: 10,
            spreadRadius: -2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Card Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: context.bgColor.withValues(alpha: 0.4),
              child: Row(
                children: [
                  // Protocol Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: target.protocol == NetworkProtocol.icmp
                          ? AppColors.primary.withValues(alpha: 0.18)
                          : AppColors.purple.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: target.protocol == NetworkProtocol.icmp
                            ? AppColors.primary.withValues(alpha: 0.4)
                            : AppColors.purple.withValues(alpha: 0.4),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      target.protocol.label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: target.protocol == NetworkProtocol.icmp
                            ? AppColors.primary
                            : AppColors.purple,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Name & Host
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          target.name,
                          style: TextStyle(
                            color: context.textPrimaryColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          target.protocol == NetworkProtocol.tcp
                              ? '${target.host}:${target.port}'
                              : target.host,
                          style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Heatmap badge
                  LatencyHeatmapIndicator(
                    latencyMs: m.lastRttMs,
                    lossRate: m.lossRate,
                    status: m.status,
                  ),
                  // Delete popup button
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, size: 16, color: context.textMutedColor),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    color: context.surfaceColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: context.borderColor),
                    ),
                    onSelected: (val) {
                      if (val == 'delete') onDeletePressed();
                    },
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            const Icon(Icons.delete_outline, size: 16, color: AppColors.latencyCritical),
                            const SizedBox(width: 8),
                            Text(
                              strings.get('deleteServer'),
                              style: const TextStyle(color: AppColors.latencyCritical, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Sparkline Graph
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: LatencySparkline(
                history: m.history,
                height: 42,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Divider(color: context.borderColor, height: 1),
            ),
            // Metrics Table
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildMetricCell(context, strings.get('min'), '${m.minRttMs.toStringAsFixed(1)} ms'),
                      _buildMetricCell(context, strings.get('avg'), '${m.avgRttMs.toStringAsFixed(1)} ms'),
                      _buildMetricCell(context, strings.get('max'), '${m.maxRttMs.toStringAsFixed(1)} ms'),
                      _buildMetricCell(context, strings.get('jitter'), '${m.jitterMs.toStringAsFixed(1)} ms'),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildMetricCell(context, strings.get('sent'), '${m.sentCount}'),
                      _buildMetricCell(context, strings.get('received'), '${m.receivedCount}'),
                      _buildMetricCell(context, strings.get('lost'), '${m.lostCount}',
                          color: m.lostCount > 0 ? AppColors.latencyCritical : null),
                      _buildMetricCell(
                        context,
                        strings.get('lossRate'),
                        '${m.lossRate.toStringAsFixed(1)}%',
                        color: m.lossRate > 0 ? AppColors.latencyCritical : AppColors.latencyFast,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCell(BuildContext context, String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: TextStyle(
            color: context.textMutedColor,
            fontSize: 9,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color ?? context.textSecondaryColor,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}

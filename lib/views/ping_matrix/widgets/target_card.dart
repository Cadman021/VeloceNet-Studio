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
  final VoidCallback onHistoryPressed;
  final VoidCallback onMutePressed;
  final VoidCallback? onEditPressed;

  /// Tapping a group badge / tag chip filters the matrix by it.
  final void Function(String group)? onGroupTap;
  final void Function(String tag)? onTagTap;

  const TargetCard({
    super.key,
    required this.target,
    required this.metric,
    required this.onDeletePressed,
    required this.onHistoryPressed,
    required this.onMutePressed,
    this.onEditPressed,
    this.onGroupTap,
    this.onTagTap,
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
    final protocolColor = _protocolColor(target.protocol);
    final showHttpMeta = target.protocol.isHttp && m.httpStatus != null;
    final showCertMeta =
        target.protocol == NetworkProtocol.https && m.certDaysLeft != null;
    final hasMetaChips = target.group != null ||
        target.tags.isNotEmpty ||
        showHttpMeta ||
        showCertMeta;

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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: protocolColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: protocolColor.withValues(alpha: 0.4),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      target.protocol.label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: protocolColor,
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
                              : target.protocol.isHttp
                                  ? '${target.host}'
                                      '${target.port == target.protocol.defaultPort ? '' : ':${target.port}'}'
                                      '${target.httpPath}'
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
                  // Muted indicator (alerts suppressed, probing continues).
                  if (target.muted)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.notifications_off_outlined,
                        size: 14,
                        color: context.textMutedColor,
                      ),
                    ),
                  // Heatmap badge
                  LatencyHeatmapIndicator(
                    latencyMs: m.lastRttMs,
                    lossRate: m.lossRate,
                    status: m.status,
                  ),
                  // Delete popup button
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert,
                        size: 16, color: context.textMutedColor),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    color: context.surfaceColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: context.borderColor),
                    ),
                    onSelected: (val) {
                      if (val == 'delete') {
                        onDeletePressed();
                      } else if (val == 'history') {
                        onHistoryPressed();
                      } else if (val == 'mute') {
                        onMutePressed();
                      } else if (val == 'edit') {
                        onEditPressed?.call();
                      }
                    },
                    itemBuilder: (ctx) => [
                      if (onEditPressed != null)
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit_outlined,
                                  size: 16, color: context.textSecondaryColor),
                              const SizedBox(width: 8),
                              Text(
                                strings.get('editServer'),
                                style: TextStyle(
                                    color: context.textPrimaryColor,
                                    fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      PopupMenuItem(
                        value: 'mute',
                        child: Row(
                          children: [
                            Icon(
                              target.muted
                                  ? Icons.notifications_active_outlined
                                  : Icons.notifications_off_outlined,
                              size: 16,
                              color: context.textSecondaryColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              strings.get(target.muted ? 'unmute' : 'mute'),
                              style: TextStyle(
                                  color: context.textPrimaryColor,
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'history',
                        child: Row(
                          children: [
                            Icon(Icons.history_rounded,
                                size: 16, color: context.textSecondaryColor),
                            const SizedBox(width: 8),
                            Text(
                              strings.get('viewHistory'),
                              style: TextStyle(
                                  color: context.textPrimaryColor,
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            const Icon(Icons.delete_outline,
                                size: 16, color: AppColors.latencyCritical),
                            const SizedBox(width: 8),
                            Text(
                              strings.get('deleteServer'),
                              style: const TextStyle(
                                  color: AppColors.latencyCritical,
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Group badge + tag chips + HTTP/TLS meta (only when set;
            // horizontally scrollable so many tags never overflow the card).
            if (hasMetaChips)
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12, top: 6),
                child: SizedBox(
                  height: 20,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        if (target.group != null)
                          _buildChip(
                            context,
                            label: target.group!,
                            icon: Icons.folder_outlined,
                            color: AppColors.cyan,
                            onTap: onGroupTap == null
                                ? null
                                : () => onGroupTap!(target.group!),
                          ),
                        if (target.group != null &&
                            (target.tags.isNotEmpty ||
                                showHttpMeta ||
                                showCertMeta))
                          const SizedBox(width: 6),
                        for (final tag in target.tags) ...[
                          _buildChip(
                            context,
                            label: tag,
                            icon: Icons.sell_outlined,
                            color: AppColors.purple,
                            onTap:
                                onTagTap == null ? null : () => onTagTap!(tag),
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (showHttpMeta)
                          _buildChip(
                            context,
                            label: 'HTTP ${m.httpStatus}',
                            icon: Icons.http,
                            color: m.httpStatus! < 400
                                ? AppColors.latencyFast
                                : AppColors.latencyCritical,
                          ),
                        if (showHttpMeta && showCertMeta)
                          const SizedBox(width: 6),
                        if (showCertMeta)
                          _buildChip(
                            context,
                            label: 'TLS ${m.certDaysLeft}d',
                            icon: Icons.lock_outline,
                            color: _certColor(m.certDaysLeft!),
                          ),
                      ],
                    ),
                  ),
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
                      _buildMetricCell(context, strings.get('min'),
                          '${m.minRttMs.toStringAsFixed(1)} ms'),
                      _buildMetricCell(context, strings.get('avg'),
                          '${m.avgRttMs.toStringAsFixed(1)} ms'),
                      _buildMetricCell(context, strings.get('max'),
                          '${m.maxRttMs.toStringAsFixed(1)} ms'),
                      _buildMetricCell(context, strings.get('jitter'),
                          '${m.jitterMs.toStringAsFixed(1)} ms'),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildMetricCell(
                          context, strings.get('sent'), '${m.sentCount}'),
                      _buildMetricCell(context, strings.get('received'),
                          '${m.receivedCount}'),
                      _buildMetricCell(
                          context, strings.get('lost'), '${m.lostCount}',
                          color: m.lostCount > 0
                              ? AppColors.latencyCritical
                              : null),
                      _buildMetricCell(
                        context,
                        strings.get('lossRate'),
                        '${m.lossRate.toStringAsFixed(1)}%',
                        color: m.lossRate > 0
                            ? AppColors.latencyCritical
                            : AppColors.latencyFast,
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

  static Color _protocolColor(NetworkProtocol protocol) {
    switch (protocol) {
      case NetworkProtocol.icmp:
        return AppColors.primary;
      case NetworkProtocol.tcp:
        return AppColors.purple;
      case NetworkProtocol.http:
        return AppColors.cyan;
      case NetworkProtocol.https:
        return AppColors.latencyFast;
    }
  }

  static Color _certColor(int daysLeft) {
    if (daysLeft <= 3) return AppColors.latencyCritical;
    if (daysLeft <= 14) return AppColors.latencyModerate;
    return AppColors.latencyFast;
  }

  Widget _buildChip(
    BuildContext context, {
    required String label,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCell(BuildContext context, String label, String value,
      {Color? color}) {
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

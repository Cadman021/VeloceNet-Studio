import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../traceroute_controller.dart';

class TracerouteStatsBar extends StatelessWidget {
  final TracerouteController controller;

  const TracerouteStatsBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final progress = controller.progress;
    final totalHops = controller.totalHops;
    final reached = controller.reachedDestination;
    final avgRtt = controller.averageRtt;
    final timeouts = controller.timeoutCount;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          // 1. Destination status badge
          _buildStatCard(
            context,
            title: strings.get('routeStatus'),
            value: reached
                ? strings.get('connected')
                : (controller.isRunning ? strings.get('tracing') : (totalHops > 0 ? strings.get('completed') : strings.get('ready'))),
            icon: reached
                ? Icons.check_circle_rounded
                : (controller.isRunning ? Icons.sync_rounded : Icons.info_outline_rounded),
            color: reached
                ? AppColors.latencyFast
                : (controller.isRunning ? AppColors.cyan : context.textSecondaryColor),
          ),
          const SizedBox(width: 8),

          // 2. Total Hops
          _buildStatCard(
            context,
            title: strings.get('hopCount'),
            value: totalHops > 0 ? '$totalHops ${strings.get('hopsUnit')}' : '-',
            icon: Icons.linear_scale_rounded,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),

          // 3. Average RTT
          _buildStatCard(
            context,
            title: strings.get('avgLatency'),
            value: avgRtt > 0 ? '${avgRtt.toStringAsFixed(1)} ms' : '-',
            icon: Icons.timer_rounded,
            color: avgRtt < 50
                ? AppColors.latencyFast
                : (avgRtt < 130 ? AppColors.latencyModerate : AppColors.latencyCritical),
          ),
          const SizedBox(width: 8),

          // 4. Target IP
          _buildStatCard(
            context,
            title: strings.get('targetIp'),
            value: progress.targetIp.isNotEmpty
                ? progress.targetIp
                : (progress.targetHost.isNotEmpty ? progress.targetHost : '-'),
            icon: Icons.public_rounded,
            color: AppColors.purple,
          ),
          const SizedBox(width: 8),

          // 5. Timeouts / Packet Loss
          _buildStatCard(
            context,
            title: strings.get('timeoutHops'),
            value: totalHops > 0 ? '$timeouts ${strings.get('nodesUnit')}' : '-',
            icon: Icons.warning_amber_rounded,
            color: timeouts > 0 ? AppColors.latencyCritical : AppColors.latencyFast,
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(
    BuildContext context, {
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: context.textMutedColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      color: context.textPrimaryColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      fontFamily: value.contains('.') && !value.contains(' ') ? 'monospace' : null,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

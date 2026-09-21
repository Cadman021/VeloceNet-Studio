import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../state/ping_matrix_controller.dart';

class StatsSummaryBar extends StatelessWidget {
  final PingMatrixController controller;
  final VoidCallback onAddTargetPressed;

  const StatsSummaryBar({
    super.key,
    required this.controller,
    required this.onAddTargetPressed,
  });

  @override
  Widget build(BuildContext context) {
    final bool isNative = controller.isNativeEngineActive;
    final strings = AppStrings.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor, width: 1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Title & Native engine indicator
              Row(
                children: [
                  const Icon(Icons.analytics_outlined, color: AppColors.cyan, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    strings.get('liveLatencyMatrix'),
                    style: TextStyle(
                      color: context.textPrimaryColor,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isNative
                          ? AppColors.latencyFast.withValues(alpha: 0.15)
                          : AppColors.latencyModerate.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isNative
                            ? AppColors.latencyFast.withValues(alpha: 0.4)
                            : AppColors.latencyModerate.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isNative ? Icons.flash_on : Icons.speed,
                          size: 13,
                          color: isNative ? AppColors.latencyFast : AppColors.latencyModerate,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isNative ? strings.get('rustFfi') : strings.get('dartFallbackMode'),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isNative ? AppColors.latencyFast : AppColors.latencyModerate,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // Control Buttons
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: controller.toggleMonitoring,
                    icon: Icon(
                      controller.isMonitoring ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 18,
                    ),
                    label: Text(controller.isMonitoring ? strings.get('stop') : strings.get('start')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: controller.isMonitoring ? AppColors.latencyModerate : AppColors.latencyFast,
                      side: BorderSide(
                        color: controller.isMonitoring
                            ? AppColors.latencyModerate.withValues(alpha: 0.5)
                            : AppColors.latencyFast.withValues(alpha: 0.5),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: controller.resetMetrics,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    tooltip: strings.get('resetStats'),
                    color: context.textSecondaryColor,
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: onAddTargetPressed,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(strings.get('addServer')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      elevation: 0,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(color: context.borderColor, height: 1),
          const SizedBox(height: 14),
          // Summary Metrics Row
          Wrap(
            spacing: 24,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            children: [
              _buildStatItem(context, strings.get('totalServers'), '${controller.totalTargets}', context.textPrimaryColor, Icons.dns),
              _buildStatItem(context, strings.get('onlineHealthy'), '${controller.onlineCount}', AppColors.latencyFast, Icons.check_circle_outline),
              _buildStatItem(context, strings.get('slowDegraded'), '${controller.degradedCount}', AppColors.latencyModerate, Icons.warning_amber_rounded),
              _buildStatItem(context, strings.get('downOffline'), '${controller.offlineCount}', AppColors.latencyCritical, Icons.error_outline),
              _buildStatItem(
                context,
                strings.get('avgLatency'),
                '${controller.averageLatency.toStringAsFixed(1)} ms',
                AppColors.cyan,
                Icons.timer_outlined,
              ),
              _buildStatItem(
                context,
                strings.get('jitter'),
                '${controller.averageJitter.toStringAsFixed(1)} ms',
                AppColors.purple,
                Icons.graphic_eq,
              ),
              _buildStatItem(
                context,
                strings.get('totalLoss'),
                '${controller.overallPacketLoss.toStringAsFixed(2)}%',
                controller.overallPacketLoss > 2 ? AppColors.latencyCritical : AppColors.latencyFast,
                Icons.difference_outlined,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(BuildContext context, String label, String value, Color color, IconData icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color.withValues(alpha: 0.8)),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: context.textMutedColor,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/alert_event.dart';
import '../../../services/metrics_csv.dart';
import '../../../state/ping_matrix_controller.dart';
import 'alert_log_dialog.dart';

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
                  ListenableBuilder(
                    listenable: controller.alertLog,
                    builder: (context, _) {
                      final unread = controller.alertLog.unreadCount;
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            onPressed: () => AlertLogDialog.show(
                                context, controller.alertLog),
                            icon: const Icon(
                                Icons.notifications_outlined, size: 20),
                            tooltip: strings.get('alerts'),
                            color: context.textSecondaryColor,
                          ),
                          if (unread > 0)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: unread > 0 &&
                                          controller.alertLog.events
                                                  .isNotEmpty &&
                                          controller.alertLog.events.first
                                                  .severity ==
                                              AlertSeverity.critical
                                      ? AppColors.latencyCritical
                                      : AppColors.primary,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  unread > 99 ? '99+' : '$unread',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  _ExportCsvButton(controller: controller),
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

/// CSV export button with in-progress and success feedback.
///
/// While an export is running the button shows a spinner and ignores taps,
/// so impatient double-clicks can't queue duplicate downloads. On success
/// a confirmation SnackBar shows the file name + size with a copy-path
/// action; on failure a localized error is shown instead.
class _ExportCsvButton extends StatefulWidget {
  final PingMatrixController controller;
  const _ExportCsvButton({required this.controller});

  @override
  State<_ExportCsvButton> createState() => _ExportCsvButtonState();
}

class _ExportCsvButtonState extends State<_ExportCsvButton> {
  bool _exporting = false;

  Future<void> _export() async {
    if (_exporting) return; // debounce double-clicks
    setState(() => _exporting = true);
    final strings = AppStrings.of(context);
    try {
      final path = await exportMetricsCsv(widget.controller.metrics);
      if (!mounted) return;
      final fileName = path.split(RegExp(r'[/\\]')).last;
      String size = '';
      try {
        final bytes = await File(path).length();
        size = bytes < 1024
            ? ' ($bytes B)'
            : ' (${(bytes / 1024).toStringAsFixed(1)} KB)';
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: AppColors.latencyFast, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${strings.get('csvSaved')}: $fileName$size',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
            ],
          ),
          backgroundColor: context.surfaceColor,
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: strings.get('copyPath'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: path));
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('CSV export failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: AppColors.latencyCritical, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(strings.get('exportFailed'))),
            ],
          ),
          backgroundColor: context.surfaceColor,
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    if (_exporting) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      onPressed: _export,
      icon: const Icon(Icons.download_rounded, size: 20),
      tooltip: strings.get('exportCsv'),
      color: context.textSecondaryColor,
    );
  }
}

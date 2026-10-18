import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../warp_controller.dart';

class WarpHeaderCard extends StatelessWidget {
  final WarpController controller;

  const WarpHeaderCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final isRunning = c.isRunning;
    final strings = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.cyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child:
                const Icon(Icons.bolt_rounded, color: AppColors.cyan, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.get('warpHeader'),
                style: TextStyle(
                    color: context.textPrimaryColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
              Text(
                strings.get('warpHeaderSub'),
                style: TextStyle(color: context.textMutedColor, fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    // Actual path in use, not mere availability: a native-capable
                    // build still falls back to Dart when the engine rejects
                    // the scan (e.g. over the endpoint cap).
                    color: c.isUsingNative
                        ? AppColors.latencyFast
                        : AppColors.latencyModerate,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  c.isUsingNative
                      ? strings.get('nativeRustUdp')
                      : strings.get('dartFallbackTcp'),
                  style: TextStyle(
                    color: c.isUsingNative
                        ? AppColors.latencyFast
                        : AppColors.latencyModerate,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: isRunning ? c.stop : c.start,
            icon: Icon(
                isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                size: 20),
            label: Text(
              isRunning
                  ? strings.get('stopScan')
                  : '${strings.get('startScan')} (${c.plannedCount} ${strings.get('endpointsUnit')})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  isRunning ? AppColors.latencyCritical : AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }
}

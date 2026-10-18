import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../portscan_controller.dart';

class PortscanHeaderCard extends StatelessWidget {
  final PortscanController controller;
  final VoidCallback onStart;

  const PortscanHeaderCard({
    super.key,
    required this.controller,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final strings = AppStrings.of(context);
    final isRunning = c.isRunning;
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
              color: AppColors.purple.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.radar, color: AppColors.purple, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.get('portScanHeader'),
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                strings.get('portScanSub'),
                style: TextStyle(color: context.textMutedColor, fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: isRunning ? c.stop : onStart,
            icon: Icon(
              isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 20,
            ),
            label: Text(
              isRunning ? strings.get('stopScan') : strings.get('startScan'),
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

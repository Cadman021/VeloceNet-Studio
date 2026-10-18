import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../dnslookup_controller.dart';

class DnsHeaderCard extends StatelessWidget {
  final DnslookupController controller;
  final VoidCallback onRun;

  const DnsHeaderCard({
    super.key,
    required this.controller,
    required this.onRun,
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
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.dns_rounded,
                color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.get('dnsHeader'),
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                strings.get('dnsSub'),
                style: TextStyle(color: context.textMutedColor, fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: isRunning ? c.stop : onRun,
            icon: Icon(
                isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                size: 20),
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

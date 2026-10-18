import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/warp_endpoint.dart';
import '../warp_controller.dart';
import 'warp_controls.dart';

class WarpConfigCard extends StatelessWidget {
  final WarpController controller;
  final TextEditingController parallelController;
  final TextEditingController timeoutController;
  final VoidCallback onApply;

  const WarpConfigCard({
    super.key,
    required this.controller,
    required this.parallelController,
    required this.timeoutController,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final strings = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.get('stepRanges'),
            style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in WarpCatalog.ranges)
                WarpSelectChip(
                  label:
                      '${r.displayName(strings.isFa)} — ${r.size} ${strings.get('addressesUnit')}',
                  selected: c.selectedRangeIds.contains(r.id),
                  onTap: c.isRunning ? null : () => c.toggleRange(r.id),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            strings.get('stepPorts'),
            style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in WarpCatalog.ports)
                WarpSelectChip(
                  label: '$p',
                  mono: true,
                  selected: c.selectedPorts.contains(p),
                  onTap: c.isRunning ? null : () => c.togglePort(p),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            strings.get('stepParallel'),
            style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              WarpNumberField(
                title: strings.get('parallelLabel'),
                controller: parallelController,
                disabled: c.isRunning,
                onApply: onApply,
              ),
              const SizedBox(width: 16),
              WarpNumberField(
                title: strings.get('timeoutLabel'),
                controller: timeoutController,
                disabled: c.isRunning,
                onApply: onApply,
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: c.isRunning ? null : onApply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(strings.get('apply'),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Text(
                '${strings.get('scanVolume')} ${c.plannedCount} ${strings.get('endpointsUnit')}',
                style: const TextStyle(
                    color: AppColors.cyan,
                    fontSize: 12,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/bandwidth_snapshot.dart';

/// Per-adapter cards with live up/down rates and link speed.
class InterfaceList extends StatelessWidget {
  final List<InterfaceStat> interfaces;

  const InterfaceList({super.key, required this.interfaces});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    if (interfaces.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.borderColor),
        ),
        child: Center(
          child: Text(
            strings.get('noInterface'),
            style: TextStyle(color: context.textMutedColor, fontSize: 12),
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final iface in interfaces)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: AppColors.cyan.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.lan_rounded, color: AppColors.cyan, size: 17),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          iface.alias.isNotEmpty ? iface.alias : iface.name,
                          style: TextStyle(
                            color: context.textPrimaryColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          iface.speedBps > 0
                              ? '${strings.get('linkSpeed')} ${formatRate(iface.speedBps.toDouble())}'
                              : strings.get('linkUnknown'),
                          style: TextStyle(color: context.textMutedColor, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  _RateChip(label: '↓', value: formatRate(iface.downBps), color: AppColors.latencyFast),
                  const SizedBox(width: 6),
                  _RateChip(label: '↑', value: formatRate(iface.upBps), color: AppColors.primary),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _RateChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _RateChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

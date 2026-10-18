import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';

class WarpSelectChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool mono;

  const WarpSelectChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.18)
              : context.bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : context.borderColor,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.primary : context.textSecondaryColor,
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            fontFamily: mono ? 'monospace' : null,
          ),
        ),
      ),
    );
  }
}

class WarpNumberField extends StatelessWidget {
  final String title;
  final TextEditingController controller;
  final bool disabled;
  final VoidCallback onApply;

  const WarpNumberField({
    super.key,
    required this.title,
    required this.controller,
    required this.disabled,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: TextStyle(color: context.textMutedColor, fontSize: 11)),
        const SizedBox(width: 6),
        Container(
          width: 70,
          height: 34,
          decoration: BoxDecoration(
            color: context.bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.borderColor),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: TextField(
              controller: controller,
              enabled: !disabled,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 12,
                  fontFamily: 'monospace'),
              decoration: const InputDecoration(
                  border: InputBorder.none, contentPadding: EdgeInsets.zero),
              onSubmitted: (_) => onApply(),
            ),
          ),
        ),
      ],
    );
  }
}

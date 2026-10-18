import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';

class DnsTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;
  final bool mono;
  final bool ltr;
  final void Function(String)? onSubmitted;

  const DnsTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.enabled,
    this.mono = false,
    this.ltr = false,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      enabled: enabled,
      style: TextStyle(
        color: context.textPrimaryColor,
        fontSize: 13,
        fontFamily: mono ? 'monospace' : null,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: context.textMutedColor, fontSize: 12),
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
      ),
      onSubmitted: onSubmitted,
    );
    final box = Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: context.bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.borderColor),
      ),
      child: ltr
          ? Directionality(textDirection: TextDirection.ltr, child: field)
          : field,
    );
    if (label.isEmpty) return box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(color: context.textSecondaryColor, fontSize: 12)),
        const SizedBox(height: 6),
        box,
      ],
    );
  }
}

class DnsNumberField extends StatelessWidget {
  final String title;
  final TextEditingController controller;
  final bool disabled;

  const DnsNumberField({
    super.key,
    required this.title,
    required this.controller,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(color: context.textSecondaryColor, fontSize: 12)),
        const SizedBox(height: 6),
        Container(
          width: 110,
          height: 42,
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
            ),
          ),
        ),
      ],
    );
  }
}

class DnsSelectChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool mono;

  const DnsSelectChip({
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

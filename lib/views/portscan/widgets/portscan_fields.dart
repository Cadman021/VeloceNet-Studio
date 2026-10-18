import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/theme_x.dart';

class PortscanTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;
  final bool mono;
  final bool ltr;
  final void Function(String)? onSubmitted;

  const PortscanTextField({
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(color: context.textSecondaryColor, fontSize: 12)),
        const SizedBox(height: 6),
        Container(
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
        ),
      ],
    );
  }
}

class PortscanNumberField extends StatelessWidget {
  final String title;
  final TextEditingController controller;
  final bool disabled;

  const PortscanNumberField({
    super.key,
    required this.title,
    required this.controller,
    required this.disabled,
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
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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

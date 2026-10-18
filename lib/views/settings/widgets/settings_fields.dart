import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/theme_x.dart';

class SettingsSecretField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final void Function(String) onChanged;
  final bool mono;
  final bool obscure;
  final String? hint;

  const SettingsSecretField({
    super.key,
    required this.controller,
    required this.label,
    required this.onChanged,
    this.mono = false,
    this.obscure = true,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(color: context.textSecondaryColor, fontSize: 12)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: context.bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.borderColor),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: TextField(
              controller: controller,
              obscureText: obscure,
              enableSuggestions: false,
              autocorrect: false,
              style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 13,
                fontFamily: mono ? 'monospace' : null,
              ),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle:
                    TextStyle(color: context.textMutedColor, fontSize: 12),
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class SettingsThresholdField extends StatelessWidget {
  final String label;
  final int value;
  final void Function(int) onChanged;

  const SettingsThresholdField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style:
                  TextStyle(color: context.textSecondaryColor, fontSize: 12)),
        ),
        const SizedBox(width: 12),
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
            child: TextFormField(
              key: ValueKey('threshold-$label-$value'),
              initialValue: '$value',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 12,
                  fontFamily: 'monospace'),
              decoration: const InputDecoration(
                  border: InputBorder.none, contentPadding: EdgeInsets.zero),
              onChanged: (v) {
                final n = int.tryParse(v.trim());
                if (n != null) onChanged(n);
              },
            ),
          ),
        ),
      ],
    );
  }
}

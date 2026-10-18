import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../portscan_controller.dart';
import 'portscan_fields.dart';

class PortscanConfigCard extends StatelessWidget {
  final PortscanController controller;
  final TextEditingController hostController;
  final TextEditingController portsController;
  final TextEditingController timeoutController;
  final TextEditingController concurrencyController;
  final VoidCallback onStart;

  const PortscanConfigCard({
    super.key,
    required this.controller,
    required this.hostController,
    required this.portsController,
    required this.timeoutController,
    required this.concurrencyController,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final strings = AppStrings.of(context);
    final disabled = c.isRunning;
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
          Row(
            children: [
              Expanded(
                flex: 4,
                child: PortscanTextField(
                  controller: hostController,
                  label: strings.get('hostLabel'),
                  hint: strings.get('hostHint'),
                  enabled: !disabled,
                  mono: true,
                  onSubmitted: (_) => !disabled ? onStart() : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 6,
                child: PortscanTextField(
                  controller: portsController,
                  label: strings.get('portsField'),
                  hint: '80,443,8000-8010',
                  enabled: !disabled,
                  mono: true,
                  ltr: true,
                  onSubmitted: (_) => !disabled ? onStart() : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              PortscanNumberField(
                  title: strings.get('timeoutLabel'),
                  controller: timeoutController,
                  disabled: disabled),
              const SizedBox(width: 16),
              PortscanNumberField(
                  title: strings.get('concurrencyLabel'),
                  controller: concurrencyController,
                  disabled: disabled),
              const Spacer(),
              if (c.error != null)
                Expanded(
                  child: Text(
                    c.error!,
                    style: const TextStyle(
                      color: AppColors.latencyCritical,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

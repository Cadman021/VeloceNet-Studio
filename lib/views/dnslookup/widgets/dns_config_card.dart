import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../services/dns_client.dart';
import '../dnslookup_controller.dart';
import 'dns_fields.dart';

class DnsConfigCard extends StatelessWidget {
  final DnslookupController controller;
  final TextEditingController hostController;
  final TextEditingController customServerController;
  final TextEditingController timeoutController;
  final DnsQueryType qtype;
  final String serverKey;
  final ValueChanged<DnsQueryType> onQtypeChanged;
  final ValueChanged<String> onServerChanged;
  final VoidCallback onRun;

  const DnsConfigCard({
    super.key,
    required this.controller,
    required this.hostController,
    required this.customServerController,
    required this.timeoutController,
    required this.qtype,
    required this.serverKey,
    required this.onQtypeChanged,
    required this.onServerChanged,
    required this.onRun,
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
                flex: 5,
                child: DnsTextField(
                  controller: hostController,
                  label: strings.get('hostLabel'),
                  hint: strings.get('hostHint'),
                  enabled: !disabled,
                  mono: true,
                  onSubmitted: (_) => !disabled ? onRun() : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: DnsNumberField(
                    title: strings.get('timeoutLabel'),
                    controller: timeoutController,
                    disabled: disabled),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            strings.get('recordType'),
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
              for (final t in DnsQueryType.values)
                DnsSelectChip(
                  label: t.label,
                  mono: true,
                  selected: qtype == t,
                  onTap: disabled ? null : () => onQtypeChanged(t),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            strings.get('dnsServer'),
            style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in kDnsServers.entries)
                DnsSelectChip(
                  label: '${entry.key} (${entry.value})',
                  mono: true,
                  selected: serverKey == entry.key,
                  onTap: disabled ? null : () => onServerChanged(entry.key),
                ),
              DnsSelectChip(
                label: strings.get('customServer'),
                selected: serverKey == '__custom__',
                onTap: disabled ? null : () => onServerChanged('__custom__'),
              ),
              if (serverKey == '__custom__')
                SizedBox(
                  width: 180,
                  child: DnsTextField(
                    controller: customServerController,
                    label: '',
                    hint: strings.get('customServerHint'),
                    enabled: !disabled,
                    mono: true,
                    ltr: true,
                    onSubmitted: (_) => !disabled ? onRun() : null,
                  ),
                ),
            ],
          ),
          if (c.error != null) ...[
            const SizedBox(height: 12),
            Text(
              c.error!,
              style: const TextStyle(
                color: AppColors.latencyCritical,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

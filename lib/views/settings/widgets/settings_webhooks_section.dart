import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import 'settings_fields.dart';
import 'settings_section.dart';

class SettingsWebhooksSection extends StatelessWidget {
  final SettingsController settings;
  final TextEditingController tgTokenController;
  final TextEditingController tgChatController;
  final TextEditingController dcUrlController;
  final TextEditingController ntfyServerController;
  final TextEditingController ntfyTopicController;
  final TextEditingController genericUrlController;
  final TextEditingController templateController;
  final TextEditingController proxyController;
  final VoidCallback onSecretChanged;
  final bool testing;
  final VoidCallback onSendTest;

  const SettingsWebhooksSection({
    super.key,
    required this.settings,
    required this.tgTokenController,
    required this.tgChatController,
    required this.dcUrlController,
    required this.ntfyServerController,
    required this.ntfyTopicController,
    required this.genericUrlController,
    required this.templateController,
    required this.proxyController,
    required this.onSecretChanged,
    required this.testing,
    required this.onSendTest,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(settings.locale);
    return SettingsSection(
      title: strings.get('webhooks'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.get('webhooksNote'),
            style: TextStyle(color: context.textMutedColor, fontSize: 12),
          ),
          if (settings.secretWarning != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 16, color: AppColors.latencyModerate),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    strings.get('secretsUnprotected'),
                    style: const TextStyle(
                        color: AppColors.latencyModerate, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Telegram'),
            value: settings.telegramEnabled,
            onChanged: (v) => settings.setTelegram(enabled: v),
          ),
          SettingsSecretField(
            controller: tgTokenController,
            label: strings.get('telegramBotToken'),
            onChanged: (_) => onSecretChanged(),
          ),
          const SizedBox(height: 8),
          SettingsSecretField(
            controller: tgChatController,
            label: strings.get('telegramChatId'),
            mono: true,
            onChanged: (_) => onSecretChanged(),
          ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Discord'),
            value: settings.discordEnabled,
            onChanged: (v) => settings.setDiscord(enabled: v),
          ),
          SettingsSecretField(
            controller: dcUrlController,
            label: strings.get('discordWebhookUrl'),
            mono: true,
            onChanged: (_) => onSecretChanged(),
          ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('ntfy'),
            value: settings.ntfyEnabled,
            onChanged: (v) => settings.setNtfy(enabled: v),
          ),
          SettingsSecretField(
            controller: ntfyServerController,
            label: strings.get('ntfyServer'),
            hint: 'https://ntfy.sh',
            mono: true,
            obscure: false,
            onChanged: (_) => onSecretChanged(),
          ),
          const SizedBox(height: 8),
          SettingsSecretField(
            controller: ntfyTopicController,
            label: strings.get('ntfyTopic'),
            hint: 'velocenet-alerts',
            mono: true,
            obscure: false,
            onChanged: (_) => onSecretChanged(),
          ),
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(strings.get('genericWebhook')),
            subtitle: Text(
              strings.get('genericWebhookHint'),
              style: TextStyle(color: context.textMutedColor, fontSize: 11),
            ),
            value: settings.genericEnabled,
            onChanged: (v) => settings.setGenericWebhook(enabled: v),
          ),
          SettingsSecretField(
            controller: genericUrlController,
            label: strings.get('genericWebhookUrl'),
            hint: 'https://example.com/hooks/velocenet',
            mono: true,
            onChanged: (_) => onSecretChanged(),
          ),
          const SizedBox(height: 12),
          SettingsSecretField(
            controller: templateController,
            label: strings.get('alertTemplate'),
            hint: strings.get('alertTemplateHint'),
            mono: true,
            obscure: false,
            onChanged: (_) => onSecretChanged(),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(strings.get('proxyTitle')),
            subtitle: Text(
              strings.get('proxyHint'),
              style: TextStyle(color: context.textMutedColor, fontSize: 11),
            ),
            value: settings.proxyEnabled,
            onChanged: (v) => settings.setProxy(enabled: v),
          ),
          SettingsSecretField(
            controller: proxyController,
            label: strings.get('proxyTitle'),
            hint: '127.0.0.1:8080',
            mono: true,
            obscure: false,
            onChanged: (_) => onSecretChanged(),
          ),
          const SizedBox(height: 12),
          SettingsThresholdField(
            label: strings.get('offlineAfterLabel'),
            value: settings.alertOfflineAfter,
            onChanged: (v) => settings.setAlertThresholds(offlineAfter: v),
          ),
          const SizedBox(height: 8),
          SettingsThresholdField(
            label: strings.get('recoverAfterLabel'),
            value: settings.alertRecoverAfter,
            onChanged: (v) => settings.setAlertThresholds(recoverAfter: v),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: ElevatedButton.icon(
              onPressed: testing ? null : onSendTest,
              icon: testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded, size: 16),
              label: Text(strings.get('sendTest')),
            ),
          ),
        ],
      ),
    );
  }
}

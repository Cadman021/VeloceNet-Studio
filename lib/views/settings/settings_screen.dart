import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_info.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/settings_controller.dart';
import '../../services/webhook_dispatcher.dart';
import 'widgets/settings_about_section.dart';
import 'widgets/settings_appearance_section.dart';
import 'widgets/settings_language_section.dart';
import 'widgets/settings_webhooks_section.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsController settings;

  /// Live alert dispatcher (owned by the shell). Used only for the
  /// test-notification buttons; null in tests/previews.
  final WebhookDispatcher? webhooks;

  const SettingsScreen({super.key, required this.settings, this.webhooks});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _tgTokenController;
  late final TextEditingController _tgChatController;
  late final TextEditingController _dcUrlController;
  late final TextEditingController _ntfyServerController;
  late final TextEditingController _ntfyTopicController;
  late final TextEditingController _genericUrlController;
  late final TextEditingController _templateController;
  late final TextEditingController _proxyController;
  bool _testing = false;

  /// Debounces secret text fields: every keystroke used to trigger a full
  /// DPAPI + prefs write round. Now keystrokes only restart this timer and
  /// a single batch save fires 600ms after the user pauses.
  Timer? _secretSaveTimer;

  SettingsController get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    _tgTokenController = TextEditingController(text: settings.telegramToken);
    _tgChatController = TextEditingController(text: settings.telegramChatId);
    _dcUrlController = TextEditingController(text: settings.discordUrl);
    _ntfyServerController =
        TextEditingController(text: settings.ntfyServer);
    _ntfyTopicController = TextEditingController(text: settings.ntfyTopic);
    _genericUrlController =
        TextEditingController(text: settings.genericUrl);
    _templateController = TextEditingController(text: settings.webhookTemplate);
    _proxyController = TextEditingController(text: settings.proxyAddress);
  }

  @override
  void dispose() {
    _secretSaveTimer?.cancel();
    _tgTokenController.dispose();
    _tgChatController.dispose();
    _dcUrlController.dispose();
    _ntfyServerController.dispose();
    _ntfyTopicController.dispose();
    _genericUrlController.dispose();
    _templateController.dispose();
    _proxyController.dispose();
    super.dispose();
  }

  void _scheduleSecretSave() {
    _secretSaveTimer?.cancel();
    _secretSaveTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _saveSecrets();
    });
  }

  Future<void> _saveSecrets() {
    return settings.saveSecretFields(
      token: _tgTokenController.text.trim(),
      chatId: _tgChatController.text.trim(),
      url: _dcUrlController.text.trim(),
      template: _templateController.text,
      proxyAddress: _proxyController.text.trim(),
      ntfyServer: _ntfyServerController.text.trim(),
      ntfyTopic: _ntfyTopicController.text.trim(),
      genericUrl: _genericUrlController.text.trim(),
    );
  }

  Future<void> _openAuthorProfile() async {
    final uri = Uri.parse(AppInfo.kAuthorUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppInfo.kAuthorUrl)),
        );
      }
    }
  }

  Future<void> _sendTest() async {
    if (_testing) return;
    setState(() => _testing = true);
    final strings = AppStrings.of(context);
    try {
      // Flush pending (debounced) edits before testing.
      _secretSaveTimer?.cancel();
      await _saveSecrets();
      final ok = await widget.webhooks?.sendTest() ?? false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? strings.get('webhookTestOk')
              : strings.get('webhookTestFail')),
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final strings = AppStrings(settings.locale);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              strings.get('settings'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            SettingsAppearanceSection(settings: settings),
            const SizedBox(height: 16),
            SettingsLanguageSection(settings: settings),
            const SizedBox(height: 16),
            SettingsWebhooksSection(
              settings: settings,
              tgTokenController: _tgTokenController,
              tgChatController: _tgChatController,
              dcUrlController: _dcUrlController,
              ntfyServerController: _ntfyServerController,
              ntfyTopicController: _ntfyTopicController,
              genericUrlController: _genericUrlController,
              templateController: _templateController,
              proxyController: _proxyController,
              onSecretChanged: _scheduleSecretSave,
              testing: _testing,
              onSendTest: _sendTest,
            ),
            const SizedBox(height: 16),
            SettingsAboutSection(
              settings: settings,
              onOpenAuthor: _openAuthorProfile,
            ),
          ],
        );
      },
    );
  }
}

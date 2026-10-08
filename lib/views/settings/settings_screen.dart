import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_info.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme/theme_x.dart';
import '../../services/webhook_dispatcher.dart';

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
  bool _testing = false;

  SettingsController get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    _tgTokenController =
        TextEditingController(text: settings.telegramToken);
    _tgChatController = TextEditingController(text: settings.telegramChatId);
    _dcUrlController = TextEditingController(text: settings.discordUrl);
  }

  @override
  void dispose() {
    _tgTokenController.dispose();
    _tgChatController.dispose();
    _dcUrlController.dispose();
    super.dispose();
  }

  Future<void> _openAuthorProfile(BuildContext context) async {
    final uri = Uri.parse(AppInfo.kAuthorUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppInfo.kAuthorUrl)),
        );
      }
    }
  }

  Future<void> _sendTest(BuildContext context) async {
    if (_testing) return;
    setState(() => _testing = true);
    final strings = AppStrings.of(context);
    try {
      // Flush pending edits before testing.
      await settings.setTelegram(
        token: _tgTokenController.text.trim(),
        chatId: _tgChatController.text.trim(),
      );
      await settings.setDiscord(url: _dcUrlController.text.trim());
      final ok = await widget.webhooks?.sendTest() ?? false;
      if (!context.mounted) return;
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
            _Section(
              title: strings.get('appearance'),
              child: _OptionTile(
                title: strings.get('theme'),
                trailing: SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(strings.get('themeSystem')),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(strings.get('themeLight')),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(strings.get('themeDark')),
                    ),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (s) => settings.setThemeMode(s.first),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: strings.get('language'),
              child: Center(
                child: SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'en',
                      label: Text(strings.get('english')),
                    ),
                    ButtonSegment(
                      value: 'fa',
                      label: Text(strings.get('farsi')),
                    ),
                    ButtonSegment(
                      value: 'ru',
                      label: Text(strings.get('russian')),
                    ),
                    ButtonSegment(
                      value: 'zh',
                      label: Text(strings.get('chinese')),
                    ),
                  ],
                  selected: {settings.locale.languageCode},
                  onSelectionChanged: (s) =>
                      settings.setLocale(Locale(s.first)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: strings.get('webhooks'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.get('webhooksNote'),
                    style: TextStyle(
                        color: context.textMutedColor, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Telegram'),
                    value: settings.telegramEnabled,
                    onChanged: (v) => settings.setTelegram(enabled: v),
                  ),
                  _secretField(
                    context,
                    controller: _tgTokenController,
                    label: strings.get('telegramBotToken'),
                    onChanged: (v) => settings.setTelegram(token: v.trim()),
                  ),
                  const SizedBox(height: 8),
                  _secretField(
                    context,
                    controller: _tgChatController,
                    label: strings.get('telegramChatId'),
                    mono: true,
                    onChanged: (v) => settings.setTelegram(chatId: v.trim()),
                  ),
                  const Divider(height: 24),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Discord'),
                    value: settings.discordEnabled,
                    onChanged: (v) => settings.setDiscord(enabled: v),
                  ),
                  _secretField(
                    context,
                    controller: _dcUrlController,
                    label: strings.get('discordWebhookUrl'),
                    mono: true,
                    onChanged: (v) => settings.setDiscord(url: v.trim()),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: ElevatedButton.icon(
                      onPressed: _testing ? null : () => _sendTest(context),
                      icon: _testing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded, size: 16),
                      label: Text(strings.get('sendTest')),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Section(
              title: strings.get('about'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(strings.get('aboutText')),
                    const SizedBox(height: 8),
                    Text(
                      '${strings.get('version')} ${AppInfo.kAppVersion}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('${strings.get('poweredBy')} '),
                        TextButton(
                          onPressed: () => _openAuthorProfile(context),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            AppInfo.kAuthorName,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _secretField(
    BuildContext context, {
    required TextEditingController controller,
    required String label,
    required void Function(String) onChanged,
    bool mono = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: context.textSecondaryColor, fontSize: 12)),
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
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 13,
                fontFamily: mono ? 'monospace' : null,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final String title;
  final Widget trailing;
  const _OptionTile({required this.title, required this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(title)),
          trailing,
        ],
      ),
    );
  }
}

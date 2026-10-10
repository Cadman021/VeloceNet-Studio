import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_info.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme/app_colors.dart';
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
  late final TextEditingController _templateController;
  late final TextEditingController _proxyController;
  bool _testing = false;

  SettingsController get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    _tgTokenController =
        TextEditingController(text: settings.telegramToken);
    _tgChatController = TextEditingController(text: settings.telegramChatId);
    _dcUrlController = TextEditingController(text: settings.discordUrl);
    _templateController =
        TextEditingController(text: settings.webhookTemplate);
    _proxyController =
        TextEditingController(text: settings.proxyAddress);
  }

  @override
  void dispose() {
    _tgTokenController.dispose();
    _tgChatController.dispose();
    _dcUrlController.dispose();
    _templateController.dispose();
    _proxyController.dispose();
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
              child: Column(
                children: [
                  _OptionTile(
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
                      onSelectionChanged: (s) =>
                          settings.setThemeMode(s.first),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.get('trayMinimize')),
                    value: settings.trayEnabled,
                    onChanged: (v) => settings.setTrayEnabled(v),
                  ),
                ],
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
                  _secretField(
                    context,
                    controller: _templateController,
                    label: strings.get('alertTemplate'),
                    hint: strings.get('alertTemplateHint'),
                    mono: true,
                    obscure: false,
                    onChanged: (v) => settings.setWebhookTemplate(v),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.get('proxyTitle')),
                    subtitle: Text(
                      strings.get('proxyHint'),
                      style: TextStyle(
                          color: context.textMutedColor, fontSize: 11),
                    ),
                    value: settings.proxyEnabled,
                    onChanged: (v) =>
                        settings.setProxy(enabled: v),
                  ),
                  _secretField(
                    context,
                    controller: _proxyController,
                    label: strings.get('proxyTitle'),
                    hint: '127.0.0.1:8080',
                    mono: true,
                    obscure: false,
                    onChanged: (v) =>
                        settings.setProxy(address: v.trim()),
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
                    const SizedBox(height: 8),
                    _UpdateRow(settings: settings),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        strings.get('autoUpdateCheck'),
                        style: const TextStyle(fontSize: 13),
                      ),
                      value: settings.updateCheckEnabled,
                      onChanged: (v) =>
                          settings.setUpdateCheckEnabled(v),
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
    bool obscure = true,
    String? hint,
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
                hintStyle: TextStyle(
                    color: context.textMutedColor, fontSize: 12),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// Update status row: auto-check result (if any), manual check button,
/// and a download action when a newer release is known. Check failures
/// stay quiet unless the user tapped check manually.
class _UpdateRow extends StatelessWidget {
  final SettingsController settings;
  const _UpdateRow({required this.settings});

  Future<void> _openReleases(BuildContext context) async {
    final uri = Uri.parse(
        'https://github.com/Cadman021/VeloceNet-Studio/releases');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('https://github.com/Cadman021/VeloceNet-Studio/releases')),
        );
      }
    }
  }

  Future<void> _checkNow(BuildContext context) async {
    final strings = AppStrings.of(context);
    final result = await settings.checkForUpdates(force: true);
    if (!context.mounted) return;
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('updateCheckFailed'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final latest = settings.latestKnownVersion;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        if (settings.checkingUpdates)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (latest != null)
          TextButton.icon(
            onPressed: () => _openReleases(context),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.system_update_rounded,
                size: 16, color: AppColors.latencyFast),
            label: Text(
              '${strings.get('updateAvailable')}: v$latest',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          )
        else
          Text(
            strings.get('upToDate'),
            style: TextStyle(
                color: context.textMutedColor, fontSize: 12),
          ),
        TextButton(
          onPressed:
              settings.checkingUpdates ? null : () => _checkNow(context),
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(strings.get('checkUpdates'),
              style: const TextStyle(fontSize: 12)),
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

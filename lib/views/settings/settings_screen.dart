import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_info.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/settings_controller.dart';

class SettingsScreen extends StatelessWidget {
  final SettingsController settings;
  const SettingsScreen({super.key, required this.settings});

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

import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/settings/settings_controller.dart';
import 'settings_section.dart';

class SettingsLanguageSection extends StatelessWidget {
  final SettingsController settings;

  const SettingsLanguageSection({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(settings.locale);
    return SettingsSection(
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
          onSelectionChanged: (s) => settings.setLocale(Locale(s.first)),
        ),
      ),
    );
  }
}

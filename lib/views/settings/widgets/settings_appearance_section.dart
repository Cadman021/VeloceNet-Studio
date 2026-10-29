import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/settings/settings_controller.dart';
import 'settings_section.dart';

class SettingsAppearanceSection extends StatelessWidget {
  final SettingsController settings;

  const SettingsAppearanceSection({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(settings.locale);
    return SettingsSection(
      title: strings.get('appearance'),
      child: Column(
        children: [
          SettingsOptionTile(
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(strings.get('trayMinimize')),
            value: settings.trayEnabled,
            onChanged: (v) => settings.setTrayEnabled(v),
          ),
          if (settings.autostartSupported)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(strings.get('launchAtLogin')),
              subtitle: Text(
                strings.get('launchAtLoginSub'),
                style: const TextStyle(fontSize: 11),
              ),
              value: settings.autostartEnabled,
              onChanged: (v) => settings.setAutostartEnabled(v),
            ),
        ],
      ),
    );
  }
}

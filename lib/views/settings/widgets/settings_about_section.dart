import 'package:flutter/material.dart';
import '../../../core/app_info.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/settings/settings_controller.dart';
import 'settings_section.dart';
import 'settings_update_row.dart';

class SettingsAboutSection extends StatelessWidget {
  final SettingsController settings;
  final VoidCallback onOpenAuthor;

  const SettingsAboutSection({
    super.key,
    required this.settings,
    required this.onOpenAuthor,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(settings.locale);
    return SettingsSection(
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
            SettingsUpdateRow(settings: settings),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                strings.get('autoUpdateCheck'),
                style: const TextStyle(fontSize: 13),
              ),
              value: settings.updateCheckEnabled,
              onChanged: (v) => settings.setUpdateCheckEnabled(v),
            ),
            const SizedBox(height: 4),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${strings.get('poweredBy')} '),
                TextButton(
                  onPressed: onOpenAuthor,
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
    );
  }
}

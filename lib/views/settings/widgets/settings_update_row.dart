import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';

class SettingsUpdateRow extends StatelessWidget {
  final SettingsController settings;

  const SettingsUpdateRow({super.key, required this.settings});

  Future<void> _openReleases(BuildContext context) async {
    final uri =
        Uri.parse('https://github.com/Cadman021/VeloceNet-Studio/releases');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'https://github.com/Cadman021/VeloceNet-Studio/releases')),
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
            style: TextStyle(color: context.textMutedColor, fontSize: 12),
          ),
        TextButton(
          onPressed: settings.checkingUpdates ? null : () => _checkNow(context),
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

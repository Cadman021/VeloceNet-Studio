import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_info.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_x.dart';

/// Startup update prompt: version, release notes preview, Download / Later.
/// Shown at most once per released version (see `dismissUpdate`).
class UpdateAvailableDialog extends StatelessWidget {
  final SettingsController settings;
  final String version;

  const UpdateAvailableDialog({
    super.key,
    required this.settings,
    required this.version,
  });

  static Future<void> showIfNeeded(
    BuildContext context,
    SettingsController settings,
  ) async {
    if (!context.mounted) return;
    if (!settings.shouldShowUpdateDialog) return;
    final version = settings.latestKnownVersion;
    if (version == null) return;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) =>
          UpdateAvailableDialog(settings: settings, version: version),
    );
    await settings.dismissUpdate(version);
  }

  Future<void> _download(BuildContext context) async {
    final uri = Uri.parse(
        'https://github.com/Cadman021/VeloceNet-Studio/releases/tag/v$version');
    await settings.dismissUpdate(version);
    if (!context.mounted) return;
    Navigator.of(context).pop();
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(uri.toString())),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final notes = settings.latestUpdateNotes;
    return Dialog(
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 560),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.latencyFast.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.system_update_rounded,
                    color: AppColors.latencyFast,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${strings.get('updateAvailable')}: v$version',
                        style: TextStyle(
                          color: context.textPrimaryColor,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${strings.get('version')} ${AppInfo.kAppVersion} → v$version',
                        style: TextStyle(
                          color: context.textMutedColor,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close,
                      size: 18, color: context.textMutedColor),
                ),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Flexible(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.bgColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: TextStyle(
                        color: context.textSecondaryColor,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(strings.get('later')),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: () => _download(context),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(strings.get('download')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
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

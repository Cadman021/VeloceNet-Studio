import 'package:material_ui/material_ui.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../services/desktop_notifier.dart';
import 'settings_section.dart';

/// OS-native alert delivery, deliberately separate from the webhook
/// channels: it works with zero third-party accounts.
class SettingsNotificationsSection extends StatelessWidget {
  final SettingsController settings;
  final DesktopNotifier? notifier;

  const SettingsNotificationsSection({
    super.key,
    required this.settings,
    this.notifier,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(settings.locale);
    return SettingsSection(
      title: strings.get('alerts'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(strings.get('desktopNotifications')),
            subtitle: Text(
              strings.get('desktopNotificationsHint'),
              style: TextStyle(color: context.textMutedColor, fontSize: 11),
            ),
            value: settings.desktopNotificationsEnabled,
            onChanged: (v) => settings.setDesktopNotificationsEnabled(v),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: OutlinedButton.icon(
              onPressed: notifier == null ? null : () => _sendTest(context),
              icon: const Icon(Icons.notifications_active_outlined, size: 16),
              label: Text(strings.get('testDesktopNotification'),
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendTest(BuildContext context) async {
    final strings = AppStrings(settings.locale);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await notifier!.test(
      title: strings.get('desktopNotificationTestTitle'),
      body: strings.get('desktopNotificationTestBody'),
    );
    if (!context.mounted) return;
    final message = ok
        ? strings.get('desktopNotificationTestBody')
        : DesktopNotificationSupport.isPlatformSupported
            ? strings.get('desktopNotificationUnavailable')
            : strings.get('desktopNotificationUnsupported');
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: ok ? AppColors.latencyFast : AppColors.latencyModerate,
      ),
    );
  }
}

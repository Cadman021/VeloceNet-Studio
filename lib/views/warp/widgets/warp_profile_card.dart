import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/warp_profile.dart';
import '../warp_controller.dart';

/// Import/validate panel for a user WireGuard profile.
///
/// The profile is deliberately session-scoped: private keys never reach
/// SharedPreferences or the SecretStore, and no tunnel is configured. The
/// only thing the engine does with the key is sign one handshake probe.
class WarpProfileCard extends StatelessWidget {
  final WarpController controller;

  const WarpProfileCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final profile = controller.profile;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined,
                  size: 18, color: AppColors.cyan),
              const SizedBox(width: 8),
              Text(
                strings.get('warpProfile'),
                style: TextStyle(
                    color: context.textPrimaryColor,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
              if (profile != null) ...[
                const SizedBox(width: 8),
                _Badge(
                  label: profile.isCloudflareWarp
                      ? strings.get('profileWarpIdentity')
                      : strings.get('profileCustomPeer'),
                  color: profile.isCloudflareWarp
                      ? AppColors.cyan
                      : AppColors.purple,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            strings.get('warpProfileHint'),
            style: TextStyle(color: context.textMutedColor, fontSize: 11),
          ),
          const SizedBox(height: 12),
          if (profile == null)
            _buildImportRow(context, strings)
          else
            _buildLoaded(context, strings, profile),
          if (controller.profileError != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline,
                    size: 15, color: AppColors.latencyCritical),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    controller.profileError!,
                    style: const TextStyle(
                        color: AppColors.latencyCritical, fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImportRow(BuildContext context, AppStrings strings) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: controller.isRunning ? null : () => _importFile(context),
          icon: const Icon(Icons.file_open_outlined, size: 16),
          label: Text(strings.get('importProfile')),
        ),
        TextButton.icon(
          onPressed: controller.isRunning ? null : () => _pasteProfile(context),
          icon: const Icon(Icons.content_paste_rounded, size: 16),
          label: Text(strings.get('pasteProfile')),
        ),
        _Badge(
          label: strings.get('profileSessionOnly'),
          color: context.textMutedColor,
        ),
        if (!controller.profileSupported)
          _Badge(
            label: strings.get('profileUnsupported'),
            color: AppColors.latencyModerate,
          ),
      ],
    );
  }

  Widget _buildLoaded(
      BuildContext context, AppStrings strings, WarpProfile profile) {
    final validation = controller.profileValidation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(
          label: strings.get('profileEndpoint'),
          value: profile.displayEndpoint,
        ),
        const SizedBox(height: 4),
        _InfoRow(
          label: strings.get('profilePeerKey'),
          value: profile.identityHint,
          tooltip: profile.publicKey,
        ),
        if (profile.addresses.isNotEmpty) ...[
          const SizedBox(height: 4),
          _InfoRow(
            label: strings.get('profileAddresses'),
            value: profile.addresses.join(', '),
          ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(strings.get('profileUseForScan'),
              style:
                  TextStyle(color: context.textSecondaryColor, fontSize: 12)),
          value: controller.useProfileForScan,
          onChanged: controller.isRunning || !controller.profileSupported
              ? null
              : (v) => controller.setUseProfileForScan(v),
        ),
        if (!controller.profileSupported) ...[
          const SizedBox(height: 2),
          _Badge(
            label: strings.get('profileUnsupported'),
            color: AppColors.latencyModerate,
          ),
        ],
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: controller.isValidatingProfile || controller.isRunning
                  ? null
                  : () => controller.validateProfile(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              icon: controller.isValidatingProfile
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.verified_user_outlined, size: 16),
              label: Text(
                controller.isValidatingProfile
                    ? strings.get('validatingProfile')
                    : strings.get('validateProfile'),
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
            OutlinedButton(
              onPressed:
                  controller.isRunning ? null : () => _importFile(context),
              child: Text(strings.get('replaceProfile'),
                  style: const TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: controller.isRunning ? null : controller.clearProfile,
              child: Text(strings.get('removeProfile'),
                  style: const TextStyle(fontSize: 12)),
            ),
            _Badge(
              label: strings.get('profileSessionOnly'),
              color: context.textMutedColor,
            ),
          ],
        ),
        if (validation != null) ...[
          const SizedBox(height: 10),
          _ValidationBanner(validation: validation),
        ],
      ],
    );
  }

  Future<void> _importFile(BuildContext context) async {
    final strings = AppStrings.of(context);
    try {
      const group = XTypeGroup(
        label: 'WireGuard profile',
        extensions: ['conf', 'txt', 'wgcf'],
      );
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) return;
      final raw = await file.readAsString();
      controller.setProfile(raw);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('profileImportFailed'))),
      );
    }
  }

  Future<void> _pasteProfile(BuildContext context) async {
    final strings = AppStrings.of(context);
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => _PasteProfileDialog(strings: strings),
    );
    if (raw == null) return;
    controller.setProfile(raw);
  }
}

class _PasteProfileDialog extends StatefulWidget {
  final AppStrings strings;
  const _PasteProfileDialog({required this.strings});

  @override
  State<_PasteProfileDialog> createState() => _PasteProfileDialogState();
}

class _PasteProfileDialogState extends State<_PasteProfileDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      title: Text(strings.get('pasteProfileTitle')),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: _controller,
          maxLines: 12,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(
            hintText: strings.get('pasteProfileHint'),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.get('cancel')),
        ),
        ElevatedButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isEmpty) return;
            Navigator.of(context).pop(text);
          },
          child: Text(strings.get('save')),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final String? tooltip;

  const _InfoRow({required this.label, required this.value, this.tooltip});

  @override
  Widget build(BuildContext context) {
    Widget text = Text(
      value,
      style: TextStyle(
        color: context.textSecondaryColor,
        fontSize: 11,
        fontFamily: 'monospace',
      ),
      overflow: TextOverflow.ellipsis,
    );
    if (tooltip != null) {
      text = Tooltip(message: tooltip!, child: text);
    }
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: TextStyle(color: context.textMutedColor, fontSize: 11),
          ),
        ),
        Expanded(child: text),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;

  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ValidationBanner extends StatelessWidget {
  final WarpProfileValidation validation;

  const _ValidationBanner({required this.validation});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final (Color color, IconData icon, String title) =
        switch (validation.status) {
      WarpProfileValidationStatus.confirmed => (
          AppColors.latencyFast,
          Icons.verified_rounded,
          strings.get('profileValidated'),
        ),
      WarpProfileValidationStatus.reachableOnly => (
          AppColors.latencyModerate,
          Icons.wifi_tethering_rounded,
          strings.get('profileReachableOnly'),
        ),
      WarpProfileValidationStatus.unsupported => (
          AppColors.latencyModerate,
          Icons.info_outline_rounded,
          strings.get('profileUnsupported'),
        ),
      WarpProfileValidationStatus.failed => (
          AppColors.latencyCritical,
          Icons.error_outline_rounded,
          strings.get('profileValidationFailed'),
        ),
    };
    final rtt = validation.rttMs >= 0
        ? ' · ${validation.rttMs.toStringAsFixed(0)} ms'
        : '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title$rtt',
                  style: TextStyle(
                      color: color, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                if (validation.detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    validation.detail,
                    style:
                        TextStyle(color: context.textMutedColor, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../services/target_config_io.dart';
import '../../../state/ping_matrix_controller.dart';

/// Paste-a-backup import dialog. No file picker needed: the user copies the
/// JSON produced by "Export servers" (or writes it by hand in the same
/// shape) and pastes it here. Parsing is fully validated; stored ids are
/// ignored and reassigned on import.
class ImportTargetsDialog extends StatefulWidget {
  final PingMatrixController controller;

  const ImportTargetsDialog({super.key, required this.controller});

  static Future<void> show(
      BuildContext context, PingMatrixController controller) {
    return showDialog(
      context: context,
      builder: (ctx) => ImportTargetsDialog(controller: controller),
    );
  }

  @override
  State<ImportTargetsDialog> createState() => _ImportTargetsDialogState();
}

class _ImportTargetsDialogState extends State<ImportTargetsDialog> {
  final TextEditingController _textController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _doImport() {
    final strings = AppStrings.of(context);
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() => _error = strings.get('invalidImport'));
      return;
    }
    final result = importTargetsJson(text);
    if (result.targets.isEmpty) {
      setState(() => _error = result.skipped > 0
          ? '${strings.get('invalidImport')} (${strings.get('skippedCount')}: ${result.skipped})'
          : strings.get('invalidImport'));
      return;
    }
    final added = widget.controller.importTargets(result.targets);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                color: AppColors.latencyFast, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${strings.get('importedCount')}: $added'
                '${result.skipped > 0 ? ' • ${strings.get('skippedCount')}: ${result.skipped}' : ''}',
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          ],
        ),
        backgroundColor: context.surfaceColor,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isNotEmpty) {
      _textController.text = text;
      setState(() => _error = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Dialog(
      child: Container(
        width: 560,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.upload_rounded,
                    color: AppColors.primary, size: 22),
                const SizedBox(width: 8),
                Text(
                  strings.get('importTitle'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimaryColor,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close,
                      size: 18, color: context.textMutedColor),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: context.bgColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.borderColor),
              ),
              child: TextField(
                controller: _textController,
                maxLines: 8,
                minLines: 5,
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: strings.get('importHint'),
                  hintStyle: TextStyle(
                      color: context.textMutedColor, fontSize: 12),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(12),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.latencyCritical,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.paste_rounded, size: 16),
                  label: Text(strings.get('paste')),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _doImport,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(strings.get('doImport')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

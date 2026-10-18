import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/warp_result.dart';

class WarpProgressCard extends StatelessWidget {
  final WarpProgress progress;

  const WarpProgressCard({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final prog = progress;
    final pct =
        prog.total > 0 ? (prog.tested / prog.total).clamp(0.0, 1.0) : 0.0;
    final strings = AppStrings.of(context);
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
              Text(
                prog.isRunning
                    ? '${strings.get('scanning')} ${prog.tested} / ${prog.total}'
                    : (prog.isCompleted
                        ? '${strings.get('scanDone')} — ${prog.succeeded} ${strings.get('succeededOf')} ${prog.total}'
                        : strings.get('readyScan')),
                style: TextStyle(
                    color: context.textPrimaryColor,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text(
                '${strings.get('okLabel')} ${prog.succeeded}   ${strings.get('failLabel')} ${prog.failed}',
                style: TextStyle(
                    color: context.textSecondaryColor,
                    fontSize: 11,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: prog.total > 0 ? pct : 0.0,
              minHeight: 8,
              backgroundColor: context.bgColor,
              valueColor: const AlwaysStoppedAnimation<Color>(AppColors.cyan),
            ),
          ),
          if (prog.error != null) ...[
            const SizedBox(height: 8),
            Text(prog.error!,
                style: const TextStyle(
                    color: AppColors.latencyCritical, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

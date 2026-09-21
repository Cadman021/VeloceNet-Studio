import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/bandwidth_snapshot.dart';

/// Top-processes table. Static header + plain rows (no ListView.separated —
/// its Dividers caused mouse_tracker asserts on Windows in phase 2).
class ProcessTable extends StatelessWidget {
  final List<ProcessTraffic> processes;
  final bool isEstimated;

  const ProcessTable({
    super.key,
    required this.processes,
    required this.isEstimated,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    TextStyle header(Color c) =>
        TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.bold);
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: context.bgColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              border: Border(bottom: BorderSide(color: context.borderColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(strings.get('colProcess'), style: header(context.textMutedColor)),
                ),
                SizedBox(
                  width: 70,
                  child: Text('PID', style: header(context.textMutedColor), textAlign: TextAlign.center),
                ),
                SizedBox(
                  width: 70,
                  child: Text(strings.get('colProtocol'), style: header(context.textMutedColor), textAlign: TextAlign.center),
                ),
                Expanded(
                  flex: 2,
                  child: Text(strings.get('colDownload'), style: header(context.textMutedColor), textAlign: TextAlign.left),
                ),
                Expanded(
                  flex: 2,
                  child: Text(strings.get('colUpload'), style: header(context.textMutedColor), textAlign: TextAlign.left),
                ),
                Expanded(
                  flex: 2,
                  child: Text(strings.get('colTotal'), style: header(context.textMutedColor), textAlign: TextAlign.left),
                ),
                if (isEstimated)
                  Text(strings.get('estimatedShort'), style: const TextStyle(color: AppColors.latencyModerate, fontSize: 10, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            child: processes.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.memory_rounded, size: 32, color: context.textMutedColor),
                        const SizedBox(height: 8),
                        Text(
                          strings.get('emptyProcesses'),
                          style: TextStyle(color: context.textMutedColor, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      children: [for (final p in processes) _ProcessRow(proc: p)],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProcessRow extends StatelessWidget {
  final ProcessTraffic proc;
  const _ProcessRow({required this.proc});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.borderColor, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              proc.name,
              style: TextStyle(color: context.textPrimaryColor, fontSize: 11, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 70,
            child: InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: '${proc.pid}'));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('PID ${proc.pid} ${strings.get('pidCopied')}'),
                    duration: const Duration(seconds: 1),
                    backgroundColor: context.surfaceColor,
                  ),
                );
              },
              child: Text(
                '${proc.pid}',
                style: const TextStyle(color: AppColors.cyan, fontSize: 11, fontFamily: 'monospace'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          SizedBox(
            width: 70,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.purple.withValues(alpha: 0.4)),
              ),
              child: Text(
                proc.protocol,
                style: const TextStyle(color: AppColors.purple, fontSize: 10, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              formatRate(proc.downBps),
              style: const TextStyle(color: AppColors.latencyFast, fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              formatRate(proc.upBps),
              style: const TextStyle(color: AppColors.primary, fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              formatRate(proc.totalBps),
              style: TextStyle(color: context.textPrimaryColor, fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

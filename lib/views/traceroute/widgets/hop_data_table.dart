import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/traceroute_hop.dart';

class HopDataTable extends StatelessWidget {
  final List<TracerouteHop> hops;
  final bool isRunning;

  const HopDataTable({
    super.key,
    required this.hops,
    required this.isRunning,
  });

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    TextStyle headerStyle(Color c) =>
        TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.bold);
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          // Table Header (static, never changes -> no layout churn)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: context.bgColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              border: Border(bottom: BorderSide(color: context.borderColor)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 50,
                  child: Text(strings.get('colHop'), style: headerStyle(context.textMutedColor)),
                ),
                SizedBox(
                  width: 90,
                  child: Text(strings.get('colNodeType'), style: headerStyle(context.textMutedColor)),
                ),
                Expanded(
                  flex: 3,
                  child: Text(strings.get('colNodeIp'), style: headerStyle(context.textMutedColor)),
                ),
                Expanded(
                  flex: 2,
                  child: Text(strings.get('colRtt'), style: headerStyle(context.textMutedColor)),
                ),
                Expanded(
                  flex: 3,
                  child: Text(strings.get('colStatus'), style: headerStyle(context.textMutedColor)),
                ),
                SizedBox(
                  width: 40,
                  child: Text(strings.get('colCopy'), style: headerStyle(context.textMutedColor), textAlign: TextAlign.center),
                ),
              ],
            ),
          ),

          // Rows area with its own internal scroll. The parent card has a
          // bounded height, so this viewport always has finite constraints.
          // NOTE: do NOT use ListView.separated here — its Divider separators
          // trigger mouse_tracker asserts on Windows desktop (see phase 2 log).
          Expanded(
            child: hops.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.table_rows_outlined, size: 36, color: context.textMutedColor),
                        const SizedBox(height: 8),
                        Text(
                          strings.get('noTableData'),
                          style: TextStyle(color: context.textMutedColor, fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      children: [
                        for (int index = 0; index < hops.length; index++)
                          _HopRow(hop: hops[index]),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _HopRow extends StatelessWidget {
  final TracerouteHop hop;
  const _HopRow({required this.hop});

  Color _rttColor() {
    if (hop.isTimeout) return AppColors.latencyCritical;
    if (hop.rttMs < 50) return AppColors.latencyFast;
    if (hop.rttMs < 130) return AppColors.latencyModerate;
    if (hop.rttMs < 220) return AppColors.latencySlow;
    return AppColors.latencyCritical;
  }

  @override
  Widget build(BuildContext context) {
    final Color rttColor = _rttColor();
    final strings = AppStrings.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.borderColor, width: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              '#${hop.hopNum}',
              style: TextStyle(
                fontFamily: 'monospace',
                color: context.textSecondaryColor,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Row(
              children: [
                Icon(
                  hop.reachedDestination
                      ? Icons.flag_circle_rounded
                      : (hop.isTimeout ? Icons.block_rounded : Icons.router_outlined),
                  size: 15,
                  color: hop.reachedDestination
                      ? AppColors.primary
                      : (hop.isTimeout ? AppColors.latencyCritical : AppColors.cyan),
                ),
                const SizedBox(width: 5),
                Text(
                  hop.reachedDestination
                      ? strings.get('nodeDest')
                      : (hop.isTimeout ? strings.get('nodeTimeout') : strings.get('nodeRouter')),
                  style: TextStyle(
                    fontSize: 11,
                    color: hop.reachedDestination
                        ? AppColors.primary
                        : (hop.isTimeout ? AppColors.latencyCritical : context.textSecondaryColor),
                    fontWeight: hop.reachedDestination ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              hop.ip,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: hop.isTimeout ? AppColors.latencyCritical : context.textPrimaryColor,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: rttColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: rttColor.withValues(alpha: 0.4)),
                ),
                child: Text(
                  hop.isTimeout ? '*' : '${hop.rttMs.toStringAsFixed(1)} ms',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: rttColor,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              hop.status.isNotEmpty ? hop.status : '-',
              style: TextStyle(
                fontSize: 11,
                color: hop.isTimeout ? AppColors.latencyCritical : context.textSecondaryColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 40,
            child: hop.ip != '*'
                ? IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 14),
                    color: context.textMutedColor,
                    tooltip: strings.get('copyIp'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: hop.ip));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${hop.ip} ${strings.get('copiedSuffix')}'),
                          duration: const Duration(seconds: 1),
                          backgroundColor: context.surfaceColor,
                        ),
                      );
                    },
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

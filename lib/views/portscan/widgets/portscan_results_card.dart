import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/port_scan.dart';
import '../portscan_controller.dart';

class PortscanResultsCard extends StatefulWidget {
  final PortscanController controller;

  const PortscanResultsCard({super.key, required this.controller});

  @override
  State<PortscanResultsCard> createState() => _PortscanResultsCardState();
}

class _PortscanResultsCardState extends State<PortscanResultsCard> {
  bool _showOnlyOpen = false;

  PortscanController get c => widget.controller;

  void _copyOpen(BuildContext context, AppStrings strings) {
    final open = c.openPorts;
    if (open.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('noOpenPorts'))),
      );
      return;
    }
    final text = open
        .map((r) => '${r.port}${r.service.isEmpty ? '' : ' (${r.service})'}')
        .join(', ');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${open.length} ${strings.get('copied')}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final list = _showOnlyOpen ? c.openPorts : c.results;
    final done = [...list]..sort((a, b) {
        if (a.state != b.state) {
          return a.state == PortState.open ? -1 : 1;
        }
        return a.port.compareTo(b.port);
      });

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Text(
                  '${strings.get('portResults')} • ${strings.get('stateOpen')}: ${c.openCount}/${c.total}',
                  style: TextStyle(
                    color: context.textPrimaryColor,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),
                _toolChip(
                  strings.get('onlyOk'),
                  _showOnlyOpen,
                  () => setState(() => _showOnlyOpen = !_showOnlyOpen),
                ),
                const Spacer(),
                _actionButton(strings.get('copyOpenPorts'), Icons.copy_rounded,
                    () => _copyOpen(context, strings)),
                const SizedBox(width: 6),
                _actionButton(
                    strings.get('clearResults'), Icons.clear_rounded, c.clear),
              ],
            ),
          ),
          Divider(color: context.borderColor, height: 1),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: context.bgColor,
            child: Row(
              children: [
                SizedBox(
                    width: 70,
                    child: Text(strings.get('port'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                Expanded(
                    flex: 3,
                    child: Text(strings.get('colService'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                Expanded(
                    flex: 2,
                    child: Text(strings.get('status'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                Expanded(
                    flex: 2,
                    child: Text(strings.get('latency'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                const SizedBox(width: 48),
              ],
            ),
          ),
          SizedBox(
            height: 320,
            child: done.isEmpty
                ? Center(
                    child: c.isRunning
                        ? Text(
                            '${strings.get('scanning')} ${c.total}',
                            style: TextStyle(
                                color: context.textMutedColor, fontSize: 12),
                          )
                        : Text(
                            strings.get('noPortResults'),
                            style: TextStyle(
                                color: context.textMutedColor, fontSize: 12),
                          ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final r in done) _resultRow(context, r),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _toolChip(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.18)
              : context.bgColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: selected ? AppColors.primary : context.borderColor),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.primary : context.textSecondaryColor,
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _actionButton(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: AppColors.primary),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(BuildContext context, PortScanResult r) {
    final Color color;
    final String stateLabel;
    final strings = AppStrings.of(context);
    switch (r.state) {
      case PortState.open:
        color = AppColors.latencyFast;
        stateLabel = strings.get('stateOpen');
        break;
      case PortState.closed:
        color = context.textSecondaryColor;
        stateLabel = strings.get('stateClosed');
        break;
      case PortState.filtered:
        color = AppColors.latencyModerate;
        stateLabel = strings.get('stateFiltered');
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: context.borderColor, width: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              '${r.port}',
              style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              r.service.isEmpty ? '—' : r.service,
              style: TextStyle(color: context.textSecondaryColor, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text(
                  stateLabel,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold, color: color),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              r.state == PortState.open
                  ? '${r.rttMs.toStringAsFixed(1)} ms'
                  : '—',
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(
            width: 48,
            child: IconButton(
              icon: const Icon(Icons.copy_rounded, size: 14),
              color: context.textMutedColor,
              tooltip: strings.get('copyEndpoint'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '${r.port}'));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${r.port} ${strings.get('copied')}'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

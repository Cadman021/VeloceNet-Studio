import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/warp_result.dart';
import '../warp_controller.dart';
import 'warp_controls.dart';

class WarpResultsCard extends StatefulWidget {
  final WarpController controller;
  final List<WarpResult> results;
  final TextEditingController topNController;
  final VoidCallback onApplyNumeric;
  final void Function(List<Map<String, dynamic>> endpoints)? onAddToPingMatrix;

  const WarpResultsCard({
    super.key,
    required this.controller,
    required this.results,
    required this.topNController,
    required this.onApplyNumeric,
    this.onAddToPingMatrix,
  });

  @override
  State<WarpResultsCard> createState() => _WarpResultsCardState();
}

class _WarpResultsCardState extends State<WarpResultsCard> {
  String _sortMode = 'rtt'; // 'rtt' | 'ip'
  bool _showOnlyOk = false;

  int _topN() {
    final n = int.tryParse(widget.topNController.text.trim()) ?? 5;
    return n.clamp(1, 50);
  }

  void _copyTop(List<WarpResult> sorted) {
    final strings = AppStrings.of(context);
    final ok = sorted.where((r) => r.success).take(_topN()).toList();
    if (ok.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('noOkToCopy'))),
      );
      return;
    }
    final lines = [
      for (int i = 0; i < ok.length; i++)
        'Endpoint = ${ok[i].endpoint}  # ${(ok[i].rttMs).toStringAsFixed(1)} ms',
    ];
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${ok.length} ${strings.get('topCopied')}')),
    );
  }

  void _addTopToMatrix() {
    final strings = AppStrings.of(context);
    final n = _topN();
    final ranked = widget.controller.progress.ranked.take(n).toList();
    if (ranked.isEmpty || widget.onAddToPingMatrix == null) return;
    widget.onAddToPingMatrix!([
      for (int i = 0; i < ranked.length; i++)
        {'ip': ranked[i].ip, 'port': ranked[i].port, 'rank': i + 1},
    ]);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$n ${strings.get('topAdded')}')),
    );
  }

  void _addOneToMatrix(WarpResult r) {
    final strings = AppStrings.of(context);
    if (widget.onAddToPingMatrix == null || !r.success) return;
    widget.onAddToPingMatrix!([
      {'ip': r.ip, 'port': r.port, 'rank': 0},
    ]);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${r.endpoint} ${strings.get('addedToMatrix')}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<WarpResult> list = List.of(widget.results);
    if (_showOnlyOk) list = list.where((r) => r.success).toList();
    if (_sortMode == 'rtt') {
      list.sort((a, b) {
        if (a.success != b.success) return a.success ? -1 : 1;
        return a.rttMs.compareTo(b.rttMs);
      });
    } else {
      list.sort((a, b) => a.endpoint.compareTo(b.endpoint));
    }
    final strings = AppStrings.of(context);

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          // Toolbar
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Text(
                  strings.get('resultsFastest'),
                  style: TextStyle(
                      color: context.textPrimaryColor,
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                _toolChip(strings.get('sortLatency'), _sortMode == 'rtt',
                    () => setState(() => _sortMode = 'rtt')),
                const SizedBox(width: 6),
                _toolChip(strings.get('sortAddr'), _sortMode == 'ip',
                    () => setState(() => _sortMode = 'ip')),
                const SizedBox(width: 6),
                _toolChip(strings.get('onlyOk'), _showOnlyOk,
                    () => setState(() => _showOnlyOk = !_showOnlyOk)),
                const Spacer(),
                WarpNumberField(
                    title: strings.get('topCount'),
                    controller: widget.topNController,
                    disabled: false,
                    onApply: widget.onApplyNumeric),
                const SizedBox(width: 8),
                _actionButton(strings.get('copyBest'), Icons.copy_rounded,
                    () => _copyTop(list)),
                const SizedBox(width: 6),
                _actionButton(strings.get('addToMatrixBtn'), Icons.add_rounded,
                    _addTopToMatrix),
              ],
            ),
          ),
          Divider(color: context.borderColor, height: 1),
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: context.bgColor,
            child: Row(
              children: [
                SizedBox(
                    width: 44,
                    child: Text(strings.get('rank'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                Expanded(
                    flex: 3,
                    child: Text(strings.get('endpoint'),
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
                Expanded(
                    flex: 3,
                    child: Text(strings.get('status'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                SizedBox(
                    width: 80,
                    child: Text(strings.get('copy'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center)),
              ],
            ),
          ),
          // Honesty footnote: TCP-indicated rows are amber on purpose.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              strings.get('viaTcpExplain'),
              style: TextStyle(color: context.textMutedColor, fontSize: 10),
            ),
          ),
          // Rows (bounded so the page keeps ONE scrollable, like hop table)
          SizedBox(
            height: 320,
            child: list.isEmpty
                ? Center(
                    child: Text(
                      strings.get('noResults'),
                      style: TextStyle(
                          color: context.textMutedColor, fontSize: 12),
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      children: [
                        for (int i = 0; i < list.length; i++)
                          _resultRow(i, list[i]),
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

  Widget _resultRow(int rank, WarpResult r) {
    final Color c;
    if (!r.success) {
      c = AppColors.latencyCritical;
    } else if (r.rttMs < 80) {
      c = AppColors.latencyFast;
    } else if (r.rttMs < 180) {
      c = AppColors.latencyModerate;
    } else {
      c = AppColors.latencySlow;
    }
    // Text rank keeps i18n/font-safe rendering (no emoji dependency).
    final rankLabel = '#${rank + 1}';
    final strings = AppStrings.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: context.borderColor, width: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(rankLabel,
                style: TextStyle(
                    color: context.textPrimaryColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          Expanded(
            flex: 3,
            child: Text(
              r.endpoint,
              style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 2,
            child: Tooltip(
              // Honest labeling: a TCP-indicated row is NOT a confirmed
              // WireGuard endpoint (the UDP probe is heuristic, not a real
              // 148-byte handshake) — it must never look identical to one.
              message: r.viaTcpFallback ? strings.get('viaTcpExplain') : '',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (r.viaTcpFallback ? AppColors.latencyModerate : c)
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: (r.viaTcpFallback ? AppColors.latencyModerate : c)
                          .withValues(alpha: 0.4)),
                ),
                child: Text(
                  !r.success
                      ? 'fail'
                      : r.viaTcpFallback
                          ? 'TCP ${r.rttMs.toStringAsFixed(1)}'
                          : '${r.rttMs.toStringAsFixed(1)} ms',
                  style: TextStyle(
                      color: r.viaTcpFallback ? AppColors.latencyModerate : c,
                      fontSize: 10,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              r.success ? (r.note ?? 'OK') : (r.note ?? 'timeout'),
              style: TextStyle(
                  color: r.success
                      ? context.textSecondaryColor
                      : AppColors.latencyCritical,
                  fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 80,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  color: context.textMutedColor,
                  tooltip: strings.get('copyEndpoint'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: r.endpoint));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content:
                              Text('${r.endpoint} ${strings.get('copied')}'),
                          duration: const Duration(seconds: 1)),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                  color: AppColors.primary,
                  tooltip: strings.get('addToPingMatrix'),
                  onPressed: () => _addOneToMatrix(r),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

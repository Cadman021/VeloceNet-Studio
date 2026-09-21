import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_x.dart';
import '../../models/warp_endpoint.dart';
import '../../models/warp_result.dart';
import 'warp_controller.dart';

class WarpScreen extends StatefulWidget {
  final WarpController controller;
  final void Function(List<Map<String, dynamic>> endpoints)? onAddToPingMatrix;

  const WarpScreen({
    super.key,
    required this.controller,
    this.onAddToPingMatrix,
  });

  @override
  State<WarpScreen> createState() => _WarpScreenState();
}

class _WarpScreenState extends State<WarpScreen> {
  final TextEditingController _parallelController = TextEditingController(text: '32');
  final TextEditingController _timeoutController = TextEditingController(text: '1200');
  final TextEditingController _topNController = TextEditingController(text: '5');
  String _sortMode = 'rtt'; // 'rtt' | 'ip'
  bool _showOnlyOk = false;

  @override
  void dispose() {
    _parallelController.dispose();
    _timeoutController.dispose();
    _topNController.dispose();
    super.dispose();
  }

  void _applyNumeric() {
    final p = int.tryParse(_parallelController.text.trim());
    final t = int.tryParse(_timeoutController.text.trim());
    if (p != null) widget.controller.setParallel(p);
    if (t != null) widget.controller.setTimeoutMs(t);
    _parallelController.text = '${widget.controller.parallel}';
    _timeoutController.text = '${widget.controller.timeoutMs}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final prog = c.progress;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeaderCard(context, c),
                const SizedBox(height: 12),
                _buildConfigCard(context, c),
                const SizedBox(height: 12),
                _buildProgressCard(context, prog, c.isNativeAvailable),
                const SizedBox(height: 12),
                _buildResultsCard(context, c, prog),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeaderCard(BuildContext context, WarpController c) {
    final isRunning = c.isRunning;
    final strings = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.cyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.bolt_rounded, color: AppColors.cyan, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.get('warpHeader'),
                style: TextStyle(color: context.textPrimaryColor, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Text(
                strings.get('warpHeaderSub'),
                style: TextStyle(color: context.textMutedColor, fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: c.isNativeAvailable ? AppColors.latencyFast : AppColors.latencyModerate,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  c.isNativeAvailable ? strings.get('nativeRustUdp') : strings.get('dartFallbackTcp'),
                  style: TextStyle(
                    color: c.isNativeAvailable ? AppColors.latencyFast : AppColors.latencyModerate,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: isRunning ? c.stop : c.start,
            icon: Icon(isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 20),
            label: Text(
              isRunning
                  ? strings.get('stopScan')
                  : '${strings.get('startScan')} (${c.plannedCount} ${strings.get('endpointsUnit')})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: isRunning ? AppColors.latencyCritical : AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigCard(BuildContext context, WarpController c) {
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
          Text(
            strings.get('stepRanges'),
            style: TextStyle(color: context.textPrimaryColor, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in WarpCatalog.ranges)
                _selectChip(
                  context,
                  label:
                      '${r.displayName(strings.isFa)} — ${r.size} ${strings.get('addressesUnit')}',
                  selected: c.selectedRangeIds.contains(r.id),
                  onTap: c.isRunning ? null : () => c.toggleRange(r.id),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            strings.get('stepPorts'),
            style: TextStyle(color: context.textPrimaryColor, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in WarpCatalog.ports)
                _selectChip(
                  context,
                  label: '$p',
                  mono: true,
                  selected: c.selectedPorts.contains(p),
                  onTap: c.isRunning ? null : () => c.togglePort(p),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            strings.get('stepParallel'),
            style: TextStyle(color: context.textPrimaryColor, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _numberField(context, strings.get('parallelLabel'), _parallelController, c.isRunning),
              const SizedBox(width: 16),
              _numberField(context, strings.get('timeoutLabel'), _timeoutController, c.isRunning),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: c.isRunning ? null : _applyNumeric,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(strings.get('apply'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Text(
                '${strings.get('scanVolume')} ${c.plannedCount} ${strings.get('endpointsUnit')}',
                style: const TextStyle(color: AppColors.cyan, fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _selectChip(BuildContext context, {required String label, required bool selected, required VoidCallback? onTap, bool mono = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.18) : context.bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : context.borderColor,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.primary : context.textSecondaryColor,
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            fontFamily: mono ? 'monospace' : null,
          ),
        ),
      ),
    );
  }

  Widget _numberField(BuildContext context, String title, TextEditingController ctl, bool disabled) {
    return Row(
      children: [
        Text(title, style: TextStyle(color: context.textMutedColor, fontSize: 11)),
        const SizedBox(width: 6),
        Container(
          width: 70,
          height: 34,
          decoration: BoxDecoration(
            color: context.bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.borderColor),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: TextField(
              controller: ctl,
              enabled: !disabled,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textPrimaryColor, fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.zero),
              onSubmitted: (_) => _applyNumeric(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressCard(BuildContext context, WarpProgress prog, bool isNative) {
    final pct = prog.total > 0 ? (prog.tested / prog.total).clamp(0.0, 1.0) : 0.0;
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
                style: TextStyle(color: context.textPrimaryColor, fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text(
                '${strings.get('okLabel')} ${prog.succeeded}   ${strings.get('failLabel')} ${prog.failed}',
                style: TextStyle(color: context.textSecondaryColor, fontSize: 11, fontFamily: 'monospace'),
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
            Text(prog.error!, style: const TextStyle(color: AppColors.latencyCritical, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _buildResultsCard(BuildContext context, WarpController c, WarpProgress prog) {
    List<WarpResult> list = List.of(prog.results);
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
                  style: TextStyle(color: context.textPrimaryColor, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                _toolChip(context, strings.get('sortLatency'), _sortMode == 'rtt', () => setState(() => _sortMode = 'rtt')),
                const SizedBox(width: 6),
                _toolChip(context, strings.get('sortAddr'), _sortMode == 'ip', () => setState(() => _sortMode = 'ip')),
                const SizedBox(width: 6),
                _toolChip(context, strings.get('onlyOk'), _showOnlyOk, () => setState(() => _showOnlyOk = !_showOnlyOk)),
                const Spacer(),
                _numberField(context, strings.get('topCount'), _topNController, false),
                const SizedBox(width: 8),
                _actionButton(strings.get('copyBest'), Icons.copy_rounded, () => _copyTop(c, list)),
                const SizedBox(width: 6),
                _actionButton(strings.get('addToMatrixBtn'), Icons.add_rounded, () => _addTopToMatrix(c)),
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
                SizedBox(width: 44, child: Text(strings.get('rank'), style: TextStyle(color: context.textMutedColor, fontSize: 11, fontWeight: FontWeight.bold))),
                Expanded(flex: 3, child: Text(strings.get('endpoint'), style: TextStyle(color: context.textMutedColor, fontSize: 11, fontWeight: FontWeight.bold))),
                Expanded(flex: 2, child: Text(strings.get('latency'), style: TextStyle(color: context.textMutedColor, fontSize: 11, fontWeight: FontWeight.bold))),
                Expanded(flex: 3, child: Text(strings.get('status'), style: TextStyle(color: context.textMutedColor, fontSize: 11, fontWeight: FontWeight.bold))),
                SizedBox(width: 80, child: Text(strings.get('copy'), style: TextStyle(color: context.textMutedColor, fontSize: 11, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
              ],
            ),
          ),
          // Rows (bounded so the page keeps ONE scrollable, like hop table)
          SizedBox(
            height: 320,
            child: list.isEmpty
                ? Center(
                    child: Text(
                      strings.get('noResults'),
                      style: TextStyle(color: context.textMutedColor, fontSize: 12),
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      children: [
                        for (int i = 0; i < list.length; i++) _resultRow(context, i, list[i]),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _toolChip(BuildContext context, String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.18) : context.bgColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? AppColors.primary : context.borderColor),
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
            Text(label, style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _resultRow(BuildContext context, int rank, WarpResult r) {
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
        border: Border(bottom: BorderSide(color: context.borderColor, width: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(rankLabel, style: TextStyle(color: context.textPrimaryColor, fontSize: 11, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            flex: 3,
            child: Text(
              r.endpoint,
              style: TextStyle(color: context.textPrimaryColor, fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: c.withValues(alpha: 0.4)),
              ),
              child: Text(
                r.success ? '${r.rttMs.toStringAsFixed(1)} ms' : 'fail',
                style: TextStyle(color: c, fontSize: 10, fontFamily: 'monospace', fontWeight: FontWeight.bold),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              r.success ? (r.note ?? 'OK') : (r.note ?? 'timeout'),
              style: TextStyle(color: r.success ? context.textSecondaryColor : AppColors.latencyCritical, fontSize: 10),
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
                      SnackBar(content: Text('${r.endpoint} ${strings.get('copied')}'), duration: const Duration(seconds: 1), backgroundColor: context.surfaceColor),
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

  int _topN() {
    final n = int.tryParse(_topNController.text.trim()) ?? 5;
    return n.clamp(1, 50);
  }

  void _copyTop(WarpController c, List<WarpResult> sorted) {
    final strings = AppStrings.of(context);
    final ok = sorted.where((r) => r.success).take(_topN()).toList();
    if (ok.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('noOkToCopy')), backgroundColor: context.surfaceColor),
      );
      return;
    }
    final lines = [
      for (int i = 0; i < ok.length; i++) 'Endpoint = ${ok[i].endpoint}  # ${(ok[i].rttMs).toStringAsFixed(1)} ms',
    ];
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${ok.length} ${strings.get('topCopied')}'), backgroundColor: context.surfaceColor),
    );
  }

  void _addTopToMatrix(WarpController c) {
    final strings = AppStrings.of(context);
    final n = _topN();
    final ranked = c.progress.ranked.take(n).toList();
    if (ranked.isEmpty || widget.onAddToPingMatrix == null) return;
    widget.onAddToPingMatrix!([
      for (int i = 0; i < ranked.length; i++)
        {'ip': ranked[i].ip, 'port': ranked[i].port, 'rank': i + 1},
    ]);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$n ${strings.get('topAdded')}'), backgroundColor: context.surfaceColor),
    );
  }

  void _addOneToMatrix(WarpResult r) {
    final strings = AppStrings.of(context);
    if (widget.onAddToPingMatrix == null || !r.success) return;
    widget.onAddToPingMatrix!([
      {'ip': r.ip, 'port': r.port, 'rank': 0},
    ]);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${r.endpoint} ${strings.get('addedToMatrix')}'), backgroundColor: context.surfaceColor),
    );
  }
}

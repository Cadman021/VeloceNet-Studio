import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_x.dart';
import '../../models/port_scan.dart';
import 'portscan_controller.dart';

class PortscanScreen extends StatefulWidget {
  const PortscanScreen({super.key});

  @override
  State<PortscanScreen> createState() => _PortscanScreenState();
}

class _PortscanScreenState extends State<PortscanScreen> {
  late final PortscanController _controller;
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portsController =
      TextEditingController(text: '21-25,53,80,110,143,443,445,3389,8080,8443');
  final TextEditingController _timeoutController =
      TextEditingController(text: '1000');
  final TextEditingController _concurrencyController =
      TextEditingController(text: '64');
  bool _showOnlyOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = PortscanController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portsController.dispose();
    _timeoutController.dispose();
    _concurrencyController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    final timeout = int.tryParse(_timeoutController.text.trim());
    final concurrency = int.tryParse(_concurrencyController.text.trim());
    if (timeout != null) {
      _timeoutController.text = '${timeout.clamp(100, 5000)}';
    }
    if (concurrency != null) {
      _concurrencyController.text = '${concurrency.clamp(1, 256)}';
    }
    _controller.start(
      _hostController.text,
      _portsController.text,
      timeoutMs: timeout ?? 1000,
      concurrency: concurrency ?? 64,
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Scaffold(
      backgroundColor: context.bgColor,
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeaderCard(context, strings, c),
                const SizedBox(height: 12),
                _buildConfigCard(context, strings, c),
                const SizedBox(height: 12),
                _buildResultsCard(context, strings, c),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeaderCard(
      BuildContext context, AppStrings strings, PortscanController c) {
    final isRunning = c.isRunning;
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
              color: AppColors.purple.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.radar, color: AppColors.purple, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.get('portScanHeader'),
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                strings.get('portScanSub'),
                style: TextStyle(color: context.textMutedColor, fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: isRunning ? c.stop : _start,
            icon: Icon(
              isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 20,
            ),
            label: Text(
              isRunning ? strings.get('stopScan') : strings.get('startScan'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  isRunning ? AppColors.latencyCritical : AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigCard(
      BuildContext context, AppStrings strings, PortscanController c) {
    final disabled = c.isRunning;
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
              Expanded(
                flex: 4,
                child: _textField(
                  context,
                  controller: _hostController,
                  label: strings.get('hostLabel'),
                  hint: strings.get('hostHint'),
                  enabled: !disabled,
                  mono: true,
                  onSubmitted: (_) => !disabled ? _start() : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 6,
                child: _textField(
                  context,
                  controller: _portsController,
                  label: strings.get('portsField'),
                  hint: '80,443,8000-8010',
                  enabled: !disabled,
                  mono: true,
                  ltr: true,
                  onSubmitted: (_) => !disabled ? _start() : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _numberField(context, strings.get('timeoutLabel'),
                  _timeoutController, disabled),
              const SizedBox(width: 16),
              _numberField(context, strings.get('concurrencyLabel'),
                  _concurrencyController, disabled),
              const Spacer(),
              if (c.error != null)
                Expanded(
                  child: Text(
                    c.error!,
                    style: const TextStyle(
                      color: AppColors.latencyCritical,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _textField(
    BuildContext context, {
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool enabled,
    bool mono = false,
    bool ltr = false,
    void Function(String)? onSubmitted,
  }) {
    final field = TextField(
      controller: controller,
      enabled: enabled,
      style: TextStyle(
        color: context.textPrimaryColor,
        fontSize: 13,
        fontFamily: mono ? 'monospace' : null,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: context.textMutedColor, fontSize: 12),
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
      ),
      onSubmitted: onSubmitted,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                TextStyle(color: context.textSecondaryColor, fontSize: 12)),
        const SizedBox(height: 6),
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: context.bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.borderColor),
          ),
          child: ltr
              ? Directionality(
                  textDirection: TextDirection.ltr, child: field)
              : field,
        ),
      ],
    );
  }

  Widget _numberField(BuildContext context, String title,
      TextEditingController ctl, bool disabled) {
    return Row(
      children: [
        Text(title,
            style: TextStyle(color: context.textMutedColor, fontSize: 11)),
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
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 12,
                  fontFamily: 'monospace'),
              decoration: const InputDecoration(
                  border: InputBorder.none, contentPadding: EdgeInsets.zero),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResultsCard(
      BuildContext context, AppStrings strings, PortscanController c) {
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
                  context,
                  strings.get('onlyOk'),
                  _showOnlyOpen,
                  () => setState(() => _showOnlyOpen = !_showOnlyOpen),
                ),
                const Spacer(),
                _actionButton(context, strings.get('copyOpenPorts'),
                    Icons.copy_rounded, () => _copyOpen(context, strings, c)),
                const SizedBox(width: 6),
                _actionButton(context, strings.get('clearResults'),
                    Icons.clear_rounded, c.clear),
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

  Widget _toolChip(
      BuildContext context, String label, bool selected, VoidCallback onTap) {
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

  Widget _actionButton(
      BuildContext context, String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
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
    final Color c;
    final String stateLabel;
    final strings = AppStrings.of(context);
    switch (r.state) {
      case PortState.open:
        c = AppColors.latencyFast;
        stateLabel = strings.get('stateOpen');
        break;
      case PortState.closed:
        c = context.textSecondaryColor;
        stateLabel = strings.get('stateClosed');
        break;
      case PortState.filtered:
        c = AppColors.latencyModerate;
        stateLabel = strings.get('stateFiltered');
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: context.borderColor, width: 0.5)),
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
              style: TextStyle(
                  color: context.textSecondaryColor, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: c.withValues(alpha: 0.4)),
                ),
                child: Text(
                  stateLabel,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold, color: c),
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
                  color: c,
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
                Clipboard.setData(
                    ClipboardData(text: '${r.port}'));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        '${r.port} ${strings.get('copied')}'),
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

  void _copyOpen(
      BuildContext context, AppStrings strings, PortscanController c) {
    final open = c.openPorts;
    if (open.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('noOpenPorts'))),
      );
      return;
    }
    final text = open
        .map((r) =>
            '${r.port}${r.service.isEmpty ? '' : ' (${r.service})'}')
        .join(', ');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('${open.length} ${strings.get('copied')}')),
    );
  }
}

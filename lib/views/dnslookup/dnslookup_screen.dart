import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_x.dart';
import '../../services/dns_client.dart';
import 'dnslookup_controller.dart';

class DnslookupScreen extends StatefulWidget {
  const DnslookupScreen({super.key});

  @override
  State<DnslookupScreen> createState() => _DnslookupScreenState();
}

class _DnslookupScreenState extends State<DnslookupScreen> {
  late final DnslookupController _controller;
  final TextEditingController _hostController =
      TextEditingController(text: 'example.com');
  final TextEditingController _customServerController =
      TextEditingController();
  final TextEditingController _timeoutController =
      TextEditingController(text: '2000');
  DnsQueryType _qtype = DnsQueryType.a;
  String _serverKey = 'Cloudflare';

  @override
  void initState() {
    super.initState();
    _controller = DnslookupController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _customServerController.dispose();
    _timeoutController.dispose();
    _controller.dispose();
    super.dispose();
  }

  String get _effectiveServer {
    if (_serverKey == '__custom__') return _customServerController.text.trim();
    return kDnsServers[_serverKey] ?? '1.1.1.1';
  }

  void _run() {
    final timeout = int.tryParse(_timeoutController.text.trim());
    final server = _effectiveServer;
    if (_serverKey == '__custom__' &&
        !_isValidServerIp(server, context)) {
      return;
    }
    _controller.query(
      rawHost: _hostController.text,
      qtype: _qtype,
      serverIp: server,
      timeoutMs: timeout ?? 2000,
    );
  }

  bool _isValidServerIp(String ip, BuildContext context) {
    final ok = InternetAddress.tryParse(ip.trim()) != null;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).get('invalidServer')),
          backgroundColor: context.surfaceColor,
        ),
      );
    }
    return ok;
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
      BuildContext context, AppStrings strings, DnslookupController c) {
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
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.dns_rounded,
                color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.get('dnsHeader'),
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                strings.get('dnsSub'),
                style: TextStyle(color: context.textMutedColor, fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: isRunning ? c.stop : _run,
            icon: Icon(
                isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                size: 20),
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
      BuildContext context, AppStrings strings, DnslookupController c) {
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
                flex: 5,
                child: _textField(
                  context,
                  controller: _hostController,
                  label: strings.get('hostLabel'),
                  hint: strings.get('hostHint'),
                  enabled: !disabled,
                  mono: true,
                  onSubmitted: (_) => !disabled ? _run() : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: _numberField(context, strings.get('timeoutLabel'),
                    _timeoutController, disabled),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            strings.get('recordType'),
            style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in DnsQueryType.values)
                _selectChip(
                  context,
                  label: t.label,
                  mono: true,
                  selected: _qtype == t,
                  onTap: disabled ? null : () => setState(() => _qtype = t),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            strings.get('dnsServer'),
            style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in kDnsServers.entries)
                _selectChip(
                  context,
                  label: '${entry.key} (${entry.value})',
                  mono: true,
                  selected: _serverKey == entry.key,
                  onTap: disabled
                      ? null
                      : () => setState(() => _serverKey = entry.key),
                ),
              _selectChip(
                context,
                label: strings.get('customServer'),
                selected: _serverKey == '__custom__',
                onTap: disabled
                    ? null
                    : () => setState(() => _serverKey = '__custom__'),
              ),
              if (_serverKey == '__custom__')
                SizedBox(
                  width: 180,
                  child: _textField(
                    context,
                    controller: _customServerController,
                    label: '',
                    hint: strings.get('customServerHint'),
                    enabled: !disabled,
                    mono: true,
                    ltr: true,
                    onSubmitted: (_) => !disabled ? _run() : null,
                  ),
                ),
            ],
          ),
          if (c.error != null) ...[
            const SizedBox(height: 12),
            Text(
              c.error!,
              style: const TextStyle(
                color: AppColors.latencyCritical,
                fontSize: 12,
              ),
            ),
          ],
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
    final box = Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: context.bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.borderColor),
      ),
      child: ltr
          ? Directionality(textDirection: TextDirection.ltr, child: field)
          : field,
    );
    if (label.isEmpty) return box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: context.textSecondaryColor, fontSize: 12)),
        const SizedBox(height: 6),
        box,
      ],
    );
  }

  Widget _numberField(BuildContext context, String title,
      TextEditingController ctl, bool disabled) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                color: context.textSecondaryColor, fontSize: 12)),
        const SizedBox(height: 6),
        Container(
          width: 110,
          height: 42,
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

  Widget _selectChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    bool mono = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.18)
              : context.bgColor,
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

  Widget _buildResultsCard(
      BuildContext context, AppStrings strings, DnslookupController c) {
    final resp = c.response;
    final records = c.records;
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
                  '${strings.get('colData')} • ${records.length}',
                  style: TextStyle(
                    color: context.textPrimaryColor,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (resp != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    '${strings.get('queryTime')}: ${resp.queryTimeMs} ms • ${resp.server}',
                    style: TextStyle(
                      color: context.textMutedColor,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                const Spacer(),
                if (records.isNotEmpty)
                  _actionButton(context, strings.get('copy'), Icons.copy_rounded,
                      () => _copyAll(context, strings, records)),
              ],
            ),
          ),
          if (resp != null && resp.truncated)
            Padding(
              padding:
                  const EdgeInsets.only(left: 12, right: 12, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.get('truncatedNote'),
                  style: const TextStyle(
                    color: AppColors.latencyModerate,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          Divider(color: context.borderColor, height: 1),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: context.bgColor,
            child: Row(
              children: [
                Expanded(
                    flex: 3,
                    child: Text(strings.get('colDomain'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                SizedBox(
                    width: 70,
                    child: Text(strings.get('colTtl'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center)),
                SizedBox(
                    width: 70,
                    child: Text('TYPE',
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center)),
                Expanded(
                    flex: 4,
                    child: Text(strings.get('colData'),
                        style: TextStyle(
                            color: context.textMutedColor,
                            fontSize: 11,
                            fontWeight: FontWeight.bold))),
                const SizedBox(width: 40),
              ],
            ),
          ),
          SizedBox(
            height: 320,
            child: records.isEmpty
                ? Center(
                    child: c.isRunning
                        ? Text(
                            strings.get('scanning'),
                            style: TextStyle(
                                color: context.textMutedColor, fontSize: 12),
                          )
                        : Text(
                            strings.get('noDnsResults'),
                            style: TextStyle(
                                color: context.textMutedColor, fontSize: 12),
                          ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final r in records) _resultRow(context, r),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _resultRow(BuildContext context, DnsRecord r) {
    final strings = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: context.borderColor, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              r.name,
              style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 70,
            child: Text(
              '${r.ttl}',
              style: TextStyle(
                  color: context.textSecondaryColor,
                  fontSize: 11,
                  fontFamily: 'monospace'),
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(
            width: 70,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.4)),
              ),
              child: Text(
                r.type,
                style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              r.data,
              style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 11,
                  fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 40,
            child: IconButton(
              icon: const Icon(Icons.copy_rounded, size: 14),
              color: context.textMutedColor,
              tooltip: strings.get('copy'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: r.data));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content:
                        Text('${r.data} ${strings.get('copied')}'),
                    duration: const Duration(seconds: 1),
                    backgroundColor: context.surfaceColor,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(BuildContext context, String label, IconData icon,
      VoidCallback onTap) {
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

  void _copyAll(BuildContext context, AppStrings strings,
      List<DnsRecord> records) {
    final text = records
        .map((r) => '${r.name} ${r.ttl} IN ${r.type} ${r.data}')
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${records.length} ${strings.get('copied')}'),
        duration: const Duration(seconds: 1),
        backgroundColor: context.surfaceColor,
      ),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../services/dns_client.dart';

class DnsResultsCard extends StatelessWidget {
  final List<DnsRecord> records;
  final DnsResponse? response;
  final bool isRunning;

  const DnsResultsCard({
    super.key,
    required this.records,
    required this.response,
    required this.isRunning,
  });

  void _copyAll(
      BuildContext context, AppStrings strings, List<DnsRecord> records) {
    final text = records
        .map((r) => '${r.name} ${r.ttl} IN ${r.type} ${r.data}')
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${records.length} ${strings.get('copied')}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final resp = response;
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
                  _actionButton(
                      context,
                      strings.get('copy'),
                      Icons.copy_rounded,
                      () => _copyAll(context, strings, records)),
              ],
            ),
          ),
          if (resp != null && resp.truncated)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
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
                    child: isRunning
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
        border:
            Border(bottom: BorderSide(color: context.borderColor, width: 0.5)),
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
                border:
                    Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
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
                    content: Text('${r.data} ${strings.get('copied')}'),
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
}

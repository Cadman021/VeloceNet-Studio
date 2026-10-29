import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_x.dart';
import '../../models/ping_metric.dart';
import '../../models/traceroute_hop.dart';
import 'mtr_controller.dart';

class MtrScreen extends StatefulWidget {
  const MtrScreen({super.key});

  @override
  State<MtrScreen> createState() => _MtrScreenState();
}

class _MtrScreenState extends State<MtrScreen> {
  late final MtrController _controller;
  final TextEditingController _hostController =
      TextEditingController(text: '8.8.8.8');

  @override
  void initState() {
    super.initState();
    _controller = MtrController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _controller.dispose();
    super.dispose();
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
                _buildTableCard(context, strings, c),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeaderCard(
      BuildContext context, AppStrings strings, MtrController c) {
    final isRunning = c.isRunning;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.route_rounded,
                    color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.get('mtrHeader'),
                    style: TextStyle(
                      color: context.textPrimaryColor,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    strings.get('mtrSub'),
                    style:
                        TextStyle(color: context.textMutedColor, fontSize: 11),
                  ),
                ],
              ),
          const Spacer(),
          // Re-trace: re-discovers the path on the same host so route
          // changes are diffed against the previous baseline and stale
          // hops are repointed. Also runs automatically every minute.
          IconButton(
            onPressed: isRunning ? c.retrace : null,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: strings.get('retrace'),
            color: context.textSecondaryColor,
          ),
          const SizedBox(width: 4),
          ElevatedButton.icon(
                onPressed: isRunning
                    ? c.stop
                    : () => c.start(_hostController.text),
                icon: Icon(
                    isRunning
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                    size: 20),
                label: Text(
                  isRunning ? strings.get('stop') : strings.get('start'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isRunning
                      ? AppColors.latencyCritical
                      : AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: context.bgColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextField(
                      controller: _hostController,
                      enabled: !isRunning,
                      style: TextStyle(
                        color: context.textPrimaryColor,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        hintText: strings.get('hostOrDomain'),
                        hintStyle: TextStyle(
                            color: context.textMutedColor, fontSize: 12),
                        border: InputBorder.none,
                        prefixIcon: Icon(Icons.public,
                            size: 18, color: context.textMutedColor),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 11),
                      ),
                      onSubmitted: (_) =>
                          !isRunning ? c.start(_hostController.text) : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _phaseChip(context, strings, c),
            ],
          ),
          if (c.hasRouteChanges) ...[
            const SizedBox(height: 12),
            _routeChangeBanner(context, strings, c),
          ],
        ],
      ),
    );
  }

  /// Amber banner shown when the latest re-trace found a different path:
  /// hop-level deltas plus a dismiss action. Stays out of the way entirely
  /// when the route is stable.
  Widget _routeChangeBanner(
      BuildContext context, AppStrings strings, MtrController c) {
    final diff = c.routeDiff;
    final summary = strings
        .get('routeChangeSummary')
        .replaceAll('{changed}', '${diff.changedCount}')
        .replaceAll('{added}', '${diff.addedCount}')
        .replaceAll('{removed}', '${diff.removedCount}');
    const amber = AppColors.latencyModerate;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: amber.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.alt_route_rounded, size: 16, color: amber),
          const SizedBox(width: 8),
          Text(
            strings.get('routeChanged'),
            style: const TextStyle(
                color: amber, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              summary,
              style: TextStyle(
                  color: context.textSecondaryColor, fontSize: 11),
            ),
          ),
          TextButton(
            onPressed: c.acknowledgeRouteChanges,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: Text(
              strings.get('routeAck'),
              style: const TextStyle(fontSize: 11, color: amber),
            ),
          ),
        ],
      ),
    );
  }

  Widget _phaseChip(
      BuildContext context, AppStrings strings, MtrController c) {
    final String label;
    final Color color;
    if (c.isDiscovering) {
      label = strings.get('mtrDiscovering');
      color = AppColors.cyan;
    } else if (c.isMonitoring) {
      label = strings.get('mtrMonitoring');
      color = AppColors.latencyFast;
    } else {
      label = strings.get('ready');
      color = context.textMutedColor;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildTableCard(
      BuildContext context, AppStrings strings, MtrController c) {
    final hops = c.hops;
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: context.bgColor,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(14)),
            ),
            child: Row(
              children: [
                SizedBox(
                    width: 44,
                    child: Text(strings.get('colHop'),
                        style: _header(context))),
                Expanded(
                    flex: 3,
                    child: Text(strings.get('colNodeIp'),
                        style: _header(context))),
                Expanded(
                    flex: 2,
                    child: Text(strings.get('totalLoss'),
                        style: _header(context))),
                Expanded(
                    flex: 2,
                    child: Text(strings.get('avg'),
                        style: _header(context))),
                Expanded(
                    flex: 2,
                    child: Text(strings.get('colBest'),
                        style: _header(context))),
                Expanded(
                    flex: 2,
                    child: Text(strings.get('colWorst'),
                        style: _header(context))),
              ],
            ),
          ),
          SizedBox(
            height: 360,
            child: hops.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        c.isDiscovering
                            ? strings.get('mtrDiscovering')
                            : c.tracer.progress.error ??
                                strings.get('mtrHint'),
                        style: TextStyle(
                            color: c.tracer.progress.error != null
                                ? AppColors.latencyCritical
                                : context.textMutedColor,
                            fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : hops.any((h) => !h.isTimeout)
                    ? SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final h in hops)
                              _hopRow(context, h,
                                  c.hopMetrics[mtrHopId(h.hopNum)]),
                          ],
                        ),
                      )
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            strings.get('mtrNoRoute'),
                            style: TextStyle(
                                color: context.textMutedColor,
                                fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  TextStyle _header(BuildContext context) => TextStyle(
      color: context.textMutedColor,
      fontSize: 11,
      fontWeight: FontWeight.bold);

  Widget _hopRow(
      BuildContext context, TracerouteHop hop, PingMetric? m) {
    final strings = AppStrings.of(context);
    final Color dot;
    final String loss;
    final String avg;
    final String best;
    final String worst;
    if (hop.isTimeout) {
      dot = context.textMutedColor;
      loss = avg = best = worst = '—';
    } else if (m == null) {
      dot = AppColors.cyan;
      loss = avg = best = worst = '…';
    } else {
      dot = AppColors.getLatencyColor(m.lastRttMs, m.lossRate);
      loss = '${m.lossRate.toStringAsFixed(1)}%';
      avg = m.avgRttMs.toStringAsFixed(1);
      best = m.minRttMs.toStringAsFixed(1);
      worst = m.maxRttMs.toStringAsFixed(1);
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
            width: 44,
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration:
                      BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  '#${hop.hopNum}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: context.textSecondaryColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              hop.ip == '*' ? '—' : hop.ip,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.textPrimaryColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final v in [loss, avg, best, worst])
            Expanded(
              flex: 2,
              child: Text(
                v,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: context.textSecondaryColor,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 14),
            color: context.textMutedColor,
            tooltip: strings.get('copyIp'),
            onPressed: hop.ip == '*'
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: hop.ip));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            '${hop.ip} ${strings.get('copiedSuffix')}'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
          ),
        ],
      ),
    );
  }
}

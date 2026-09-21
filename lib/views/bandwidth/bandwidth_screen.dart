import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_x.dart';
import '../../models/bandwidth_snapshot.dart';
import 'bandwidth_controller.dart';
import 'widgets/bandwidth_chart.dart';
import 'widgets/interface_list.dart';
import 'widgets/process_table.dart';

class BandwidthScreen extends StatefulWidget {
  const BandwidthScreen({super.key});

  @override
  State<BandwidthScreen> createState() => _BandwidthScreenState();
}

class _BandwidthScreenState extends State<BandwidthScreen> {
  late final BandwidthController _controller;
  final TextEditingController _windowController = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    _controller = BandwidthController();
  }

  @override
  void dispose() {
    _windowController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _applyWindow() {
    final minutes = int.tryParse(_windowController.text.trim());
    if (minutes == null) {
      final strings = AppStrings.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.get('enterValidNumber')),
          duration: const Duration(seconds: 2),
          backgroundColor: context.surfaceColor,
        ),
      );
      return;
    }
    _controller.setWindowMinutes(minutes);
    _windowController.text = '${_controller.windowMinutes}';
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Scaffold(
      backgroundColor: context.bgColor,
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final isRunning = _controller.isRunning;
          final latest = _controller.latest;
          final isNative = _controller.isNativeAvailable;

          return LayoutBuilder(
            builder: (context, constraints) {
              final double tableHeight =
                  (constraints.maxHeight * 0.42).clamp(260.0, 520.0);

              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                physics: const BouncingScrollPhysics(),
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minHeight: constraints.maxHeight - 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Header + start/stop + window-minutes field
                      _buildHeaderBar(isRunning, isNative),
                      const SizedBox(height: 12),

                      // 2. Live totals
                      _buildTotalsRow(latest),
                      const SizedBox(height: 12),

                      // 3. Chart card
                      Container(
                        width: double.infinity,
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
                                  strings.get('liveChart'),
                                  style: TextStyle(
                                    color: context.textPrimaryColor,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                if (latest.isEstimated && latest.note != null)
                                  Text(
                                    latest.note!,
                                    style: const TextStyle(
                                      color: AppColors.latencyModerate,
                                      fontSize: 10,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            BandwidthChart(history: _controller.history),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 4. Interfaces
                      Text(
                        strings.get('networkInterfaces'),
                        style: TextStyle(
                          color: context.textPrimaryColor,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      InterfaceList(interfaces: latest.interfaces),
                      const SizedBox(height: 12),

                      // 5. Processes table (bounded height, own scroll)
                      Row(
                        children: [
                          Text(
                            strings.get('topProcesses'),
                            style: TextStyle(
                              color: context.textPrimaryColor,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (latest.isEstimated)
                            Text(
                              strings.get('estimatedNote'),
                              style: const TextStyle(
                                color: AppColors.latencyModerate,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: tableHeight,
                        child: ProcessTable(
                          processes: latest.topProcesses,
                          isEstimated: latest.isEstimated,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildHeaderBar(bool isRunning, bool isNative) {
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
            child: const Icon(Icons.speed_rounded, color: AppColors.cyan, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.get('liveBandwidth'),
                style: TextStyle(
                  color: context.textPrimaryColor,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                strings.get('liveBandwidthSub'),
                style: TextStyle(color: context.textMutedColor, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(width: 16),

          // History window (minutes) — user configurable, default 1.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: context.bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                Text(
                  strings.get('historyMin'),
                  style: TextStyle(color: context.textMutedColor, fontSize: 11),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 52,
                  height: 30,
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextField(
                      controller: _windowController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.textPrimaryColor,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (_) => _applyWindow(),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: _applyWindow,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      strings.get('apply'),
                      style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Engine badge
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
                    color: isNative ? AppColors.latencyFast : AppColors.latencyModerate,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  isNative ? strings.get('nativeRust') : strings.get('coreUnavailable'),
                  style: TextStyle(
                    color: isNative ? AppColors.latencyFast : AppColors.latencyModerate,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          ElevatedButton.icon(
            onPressed: isRunning ? _controller.stop : _controller.start,
            icon: Icon(
              isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 20,
            ),
            label: Text(
              isRunning ? strings.get('stopMonitoring') : strings.get('startMonitoring'),
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

  Widget _buildTotalsRow(BandwidthSnapshot latest) {
    final strings = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          _TotalCard(
            title: strings.get('downloadNow'),
            value: formatRate(latest.downBps),
            icon: Icons.arrow_downward_rounded,
            color: AppColors.latencyFast,
          ),
          const SizedBox(width: 8),
          _TotalCard(
            title: strings.get('uploadNow'),
            value: formatRate(latest.upBps),
            icon: Icons.arrow_upward_rounded,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          _TotalCard(
            title: strings.get('totalThroughput'),
            value: formatRate(latest.totalBps),
            icon: Icons.swap_vert_rounded,
            color: AppColors.cyan,
          ),
          const SizedBox(width: 8),
          _TotalCard(
            title: strings.get('chartSamples'),
            value: '${_controller.history.length} / ${_controller.maxSamples}',
            icon: Icons.timeline_rounded,
            color: AppColors.purple,
          ),
        ],
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _TotalCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: context.textMutedColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      color: context.textPrimaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

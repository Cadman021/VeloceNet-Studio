import 'package:flutter/material.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_x.dart';
import 'traceroute_controller.dart';
import 'widgets/hop_data_table.dart';
import 'widgets/traceroute_stats_bar.dart';
import 'widgets/visual_node_chain.dart';

class TracerouteScreen extends StatefulWidget {
  const TracerouteScreen({super.key});

  @override
  State<TracerouteScreen> createState() => _TracerouteScreenState();
}

class _TracerouteScreenState extends State<TracerouteScreen> {
  final TextEditingController _hostController =
      TextEditingController(text: '8.8.8.8');
  late final TracerouteController _controller;

  final List<Map<String, String>> _presets = [
    {'name': 'Google DNS', 'host': '8.8.8.8'},
    {'name': 'Cloudflare', 'host': '1.1.1.1'},
    {'name': 'GitHub', 'host': 'github.com'},
    {'name': 'Quad9', 'host': '9.9.9.9'},
  ];

  @override
  void initState() {
    super.initState();
    _controller = TracerouteController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _startTraceroute() {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    _controller.start(host);
  }

  void _stopTraceroute() {
    _controller.stop();
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
          final hops = _controller.hops;

          return LayoutBuilder(
            builder: (context, constraints) {
              // Whole page scrolls vertically when content is taller
              // than the window (e.g. 30 hops). Each inner section keeps
              // a bounded height so no unbounded-height layout error and
              // no nested-scrollable fight can occur.
              final double diagramHeight =
                  (constraints.maxHeight * 0.42).clamp(220.0, 420.0);

              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                physics: const BouncingScrollPhysics(),
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minHeight: constraints.maxHeight - 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header bar (proven working, untouched)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(14),
                          border:
                              Border.all(color: context.borderColor),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.alt_route_rounded,
                                color: AppColors.primary, size: 22),
                            const SizedBox(width: 12),
                            Text(
                              strings.get('visualTraceroute'),
                              style: TextStyle(
                                color: context.textPrimaryColor,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Container(
                                height: 42,
                                decoration: BoxDecoration(
                                  color: context.bgColor,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: context.borderColor),
                                ),
                                child: Directionality(
                                  textDirection: TextDirection.ltr,
                                  child: TextField(
                                    controller: _hostController,
                                    style: TextStyle(
                                      color: context.textPrimaryColor,
                                      fontSize: 13,
                                      fontFamily: 'monospace',
                                    ),
                                    decoration: InputDecoration(
                                      hintText: strings.get('hostOrDomain'),
                                      hintStyle: TextStyle(
                                          color: context.textMutedColor,
                                          fontSize: 12),
                                      border: InputBorder.none,
                                      prefixIcon: Icon(Icons.public,
                                          size: 18,
                                          color: context.textMutedColor),
                                      contentPadding: const EdgeInsets.symmetric(
                                          vertical: 11),
                                    ),
                                    onSubmitted: (_) => isRunning
                                        ? _stopTraceroute()
                                        : _startTraceroute(),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton.icon(
                              onPressed: isRunning
                                  ? _stopTraceroute
                                  : _startTraceroute,
                              icon: Icon(
                                isRunning
                                    ? Icons.stop_rounded
                                    : Icons.play_arrow_rounded,
                                size: 20,
                              ),
                              label: Text(
                                isRunning
                                    ? strings.get('stopTraceroute')
                                    : strings.get('startTraceroute'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isRunning
                                    ? AppColors.latencyCritical
                                    : AppColors.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Preset chips (InkWell, no ActionChip overlay)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Row(
                          children: [
                            Text(
                              strings.get('suggestedTargets'),
                              style: TextStyle(
                                  color: context.textMutedColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 8),
                            for (final p in _presets)
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 6),
                                child: InkWell(
                                  onTap: () {
                                    _hostController.text =
                                        p['host']!;
                                    _startTraceroute();
                                  },
                                  borderRadius:
                                      BorderRadius.circular(16),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: context.surfaceColor,
                                      borderRadius:
                                          BorderRadius.circular(16),
                                      border: Border.all(
                                          color:
                                              context.borderColor),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          p['name']!,
                                          style: TextStyle(
                                              color:
                                                  context.textPrimaryColor,
                                              fontSize: 11),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '(${p['host']})',
                                          style: const TextStyle(
                                            color: AppColors.cyan,
                                            fontSize: 10,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Stats summary
                      TracerouteStatsBar(
                          controller: _controller),
                      const SizedBox(height: 12),

                      // Visual node diagram: bounded height + its OWN
                      // internal scroll (horizontal + vertical). The card
                      // never grows unbounded, so the page can never
                      // overflow no matter how many hops arrive.
                      Container(
                        width: double.infinity,
                        height: diagramHeight,
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius:
                              BorderRadius.circular(14),
                          border: Border.all(
                              color: context.borderColor),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: VisualNodeChain(
                          hops: hops,
                          isRunning: isRunning,
                          targetHost:
                              _controller.progress.targetHost,
                          targetIp:
                              _controller.progress.targetIp,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Table: bounded height (min 280) with its own
                      // internal scroll. Never unbounded, never overflows.
                      SizedBox(
                        height: (constraints.maxHeight * 0.5)
                            .clamp(280.0, 560.0),
                        child: HopDataTable(
                            hops: hops, isRunning: isRunning),
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
}

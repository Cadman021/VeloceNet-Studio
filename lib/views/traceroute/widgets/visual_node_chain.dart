import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/traceroute_hop.dart';

/// Safe visual node chain with its OWN bounded scrollable viewport.
///
/// Stability rules (learned from the Windows mouse_tracker hangs):
/// - NO AnimationController / CircularProgressIndicator (endless tickers).
/// - Self-contained scroll: a horizontal SingleChildScrollView for the
///   node chain, wrapped in a vertical SingleChildScrollView fallback.
///   The parent gives this widget a BOUNDED height, so the viewport always
///   has finite constraints -> no "RenderBox was not laid out" errors.
/// - Stateless: rebuilds only when hops/isRunning actually change.
class VisualNodeChain extends StatelessWidget {
  final List<TracerouteHop> hops;
  final bool isRunning;
  final String targetHost;
  final String targetIp;

  const VisualNodeChain({
    super.key,
    required this.hops,
    required this.isRunning,
    required this.targetHost,
    required this.targetIp,
  });

  @override
  Widget build(BuildContext context) {
    if (hops.isEmpty && !isRunning) {
      final strings = AppStrings.of(context);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.alt_route_rounded, size: 38, color: AppColors.primary),
            const SizedBox(height: 12),
            Text(
              strings.get('visualReady'),
              style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              strings.get('visualHint'),
              style: TextStyle(color: context.textSecondaryColor, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scrollbar(
        thumbVisibility: false,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: _buildChain(context),
        ),
      ),
    );
  }

  Widget _buildChain(BuildContext context) {
    // Horizontal chain: origin + hops + optional searching node.
    // Wrapped in its own horizontal scroll so 30 hops never overflow.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildOriginNode(),
          for (int i = 0; i < hops.length; i++) ...[
            _buildConnectionLine(hops[i]),
            _buildHopNode(context, hops[i]),
          ],
          if (isRunning &&
              (hops.isEmpty || !hops.last.reachedDestination)) ...[
            _buildSearchingLine(),
            _buildSearchingNode(context),
          ],
        ],
      ),
    );
  }

  Widget _buildOriginNode() {
    return Builder(builder: (context) {
      return Container(
        width: 118,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.6), width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.computer_rounded, color: AppColors.primary, size: 22),
            const SizedBox(height: 6),
            Text(
              'Local Host',
              style: TextStyle(
                color: context.textPrimaryColor,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              '127.0.0.1',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: AppColors.cyan,
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildHopNode(BuildContext context, TracerouteHop hop) {
    final Color nodeColor = _nodeColor(hop);
    final IconData nodeIcon = hop.reachedDestination
        ? Icons.flag_rounded
        : (hop.isTimeout ? Icons.timer_off_rounded : Icons.router_rounded);

    return Container(
      width: 128,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: nodeColor.withValues(alpha: 0.7),
          width: hop.reachedDestination ? 2.0 : 1.2,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: nodeColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Hop #${hop.hopNum}',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: nodeColor,
                  ),
                ),
              ),
              if (hop.reachedDestination)
                const Icon(Icons.check_circle,
                    color: AppColors.latencyFast, size: 13),
            ],
          ),
          const SizedBox(height: 6),
          Icon(nodeIcon, color: nodeColor, size: 22),
          const SizedBox(height: 6),
          Text(
            hop.ip,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: hop.isTimeout
                  ? AppColors.latencyCritical
                  : context.textPrimaryColor,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            hop.isTimeout ? 'Time Out (*)' : '${hop.rttMs.toStringAsFixed(1)} ms',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: nodeColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchingNode(BuildContext context) {
    return Container(
      width: 110,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.cyan.withValues(alpha: 0.6),
          width: 1.2,
        ),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_rounded, color: AppColors.cyan, size: 22),
          SizedBox(height: 6),
          Text(
            'Searching...',
            style: TextStyle(
              color: AppColors.cyan,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionLine(TracerouteHop hop) {
    final Color lineColor;
    if (hop.isTimeout) {
      lineColor = AppColors.latencyCritical.withValues(alpha: 0.6);
    } else if (hop.rttMs < 50) {
      lineColor = AppColors.latencyFast;
    } else if (hop.rttMs < 130) {
      lineColor = AppColors.latencyModerate;
    } else {
      lineColor = AppColors.latencySlow;
    }

    return Container(
      width: 28,
      height: 3,
      margin: const EdgeInsets.only(top: 56, left: 2, right: 2),
      decoration: BoxDecoration(
        color: lineColor,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildSearchingLine() {
    return Container(
      width: 28,
      height: 3,
      margin: const EdgeInsets.only(top: 56, left: 2, right: 2),
      decoration: BoxDecoration(
        color: AppColors.cyan.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Color _nodeColor(TracerouteHop hop) {
    if (hop.isTimeout) return AppColors.latencyCritical;
    if (hop.reachedDestination) return AppColors.primary;
    if (hop.rttMs < 50) return AppColors.latencyFast;
    if (hop.rttMs < 130) return AppColors.latencyModerate;
    if (hop.rttMs < 220) return AppColors.latencySlow;
    return AppColors.latencyCritical;
  }
}

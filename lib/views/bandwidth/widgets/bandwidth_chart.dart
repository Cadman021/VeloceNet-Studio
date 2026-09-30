import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/bandwidth_snapshot.dart';

/// Live up/down throughput chart drawn with CustomPainter (same stable
/// pattern as the ping-matrix sparkline: no chart package, no tickers).
class BandwidthChart extends StatelessWidget {
  final List<BandwidthSnapshot> history;

  const BandwidthChart({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    if (history.isEmpty) {
      return SizedBox(
        height: 160,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.show_chart_rounded, size: 36, color: context.textMutedColor),
              const SizedBox(height: 8),
              Text(
                strings.get('chartEmpty'),
                style: TextStyle(color: context.textMutedColor, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Legend
        Row(
          children: [
            _LegendDot(color: AppColors.latencyFast, label: strings.get('legendDown')),
            const SizedBox(width: 16),
            _LegendDot(color: AppColors.primary, label: strings.get('legendUp')),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 160,
          width: double.infinity,
          child: CustomPaint(
            painter: _BandwidthPainter(history: history),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
      ],
    );
  }
}

class _BandwidthPainter extends CustomPainter {
  final List<BandwidthSnapshot> history;
  _BandwidthPainter({required this.history});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;

    double maxVal = 1.0;
    for (final s in history) {
      if (s.downBps > maxVal) maxVal = s.downBps;
      if (s.upBps > maxVal) maxVal = s.upBps;
    }
    // Headroom so the peak never touches the top edge.
    maxVal *= 1.15;

    final stepX = size.width / (history.length - 1);

    void drawSeries(List<double> Function(BandwidthSnapshot) pick, Color color) {
      final path = Path();
      final fill = Path();
      for (int i = 0; i < history.length; i++) {
        final v = pick(history[i]).first;
        final x = i * stepX;
        final y = size.height - (v / maxVal) * (size.height - 10) - 5;
        if (i == 0) {
          path.moveTo(x, y);
          fill.moveTo(x, size.height);
          fill.lineTo(x, y);
        } else {
          path.lineTo(x, y);
          fill.lineTo(x, y);
        }
      }
      fill.lineTo(size.width, size.height);
      fill.close();

      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.02)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
        ..style = PaintingStyle.fill;
      canvas.drawPath(fill, fillPaint);

      final linePaint = Paint()
        ..color = color
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, linePaint);
    }

    // Down first (under), up second (over).
    drawSeries((s) => [s.downBps], AppColors.latencyFast);
    drawSeries((s) => [s.upBps], AppColors.primary);

    // Peak label
    final peak = TextPainter(
      text: TextSpan(
        text: 'peak ${formatRate(maxVal / 1.15)}',
        style: const TextStyle(color: AppColors.textMuted, fontSize: 10, fontFamily: 'monospace'),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    peak.paint(canvas, Offset(size.width - peak.width - 4, 2));
  }

  // Same contract as the ping sparkline: repaint only when length or
  // the window edges moved (append-only history, newest last).
  @override
  bool shouldRepaint(covariant _BandwidthPainter old) {
    if (identical(history, old.history)) return false;
    if (history.length != old.history.length) return true;
    if (history.isEmpty) return false;
    final a = history.first;
    final b = old.history.first;
    final c = history.last;
    final d = old.history.last;
    return a.downBps != b.downBps ||
        a.upBps != b.upBps ||
        c.downBps != d.downBps ||
        c.upBps != d.upBps;
  }
}

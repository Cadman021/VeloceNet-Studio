import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';

class LatencySparkline extends StatelessWidget {
  final List<double> history;
  final double height;
  final Color? lineColor;

  const LatencySparkline({
    super.key,
    required this.history,
    this.height = 48.0,
    this.lineColor,
  });

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      final strings = AppStrings.of(context);
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            strings.get('measuring'),
            style: TextStyle(color: context.textMutedColor, fontSize: 11),
          ),
        ),
      );
    }

    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SparklinePainter(
          history: history,
          overrideColor: lineColor,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> history;
  final Color? overrideColor;

  _SparklinePainter({required this.history, this.overrideColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;

    // Filter valid positive values for min/max calculation
    final validValues = history.where((v) => v >= 0).toList();
    if (validValues.isEmpty) {
      // All lost / offline line
      final offlinePaint = Paint()
        ..color = AppColors.latencyCritical.withValues(alpha: 0.5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        offlinePaint,
      );
      return;
    }

    double minVal = validValues.reduce((a, b) => a < b ? a : b);
    double maxVal = validValues.reduce((a, b) => a > b ? a : b);

    if (maxVal - minVal < 10) {
      maxVal = minVal + 10;
    }

    final double stepX = size.width / (history.length - 1);

    final Path path = Path();
    final Path fillPath = Path();

    bool isFirst = true;

    for (int i = 0; i < history.length; i++) {
      final val = history[i];
      final x = i * stepX;

      if (val < 0) {
        // Lost packet sample
        if (!isFirst) {
          final lastY = size.height - 2;
          path.lineTo(x, lastY);
        }
        continue;
      }

      final normalizedY = (val - minVal) / (maxVal - minVal);
      final y = size.height - (normalizedY * (size.height - 8)) - 4;

      if (isFirst) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
        isFirst = false;
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    if (!isFirst) {
      fillPath.lineTo((history.length - 1) * stepX, size.height);
      fillPath.close();
    }

    final lastVal = history.last;
    final strokeColor = overrideColor ??
        (lastVal < 0
            ? AppColors.latencyCritical
            : AppColors.getLatencyColor(lastVal, 0.0));

    // Paint gradient fill under graph
    final fillGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        strokeColor.withValues(alpha: 0.35),
        strokeColor.withValues(alpha: 0.02),
      ],
    );

    final fillPaint = Paint()
      ..shader = fillGradient.createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // Paint main path line
    final linePaint = Paint()
      ..color = strokeColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, linePaint);

    // Paint lost packet indicators (red dots at bottom)
    final lostDotPaint = Paint()..color = AppColors.latencyCritical;
    for (int i = 0; i < history.length; i++) {
      if (history[i] < 0) {
        canvas.drawCircle(Offset(i * stepX, size.height - 3), 2.0, lostDotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) => true;
}

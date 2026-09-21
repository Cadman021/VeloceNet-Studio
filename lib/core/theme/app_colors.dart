import 'package:flutter/material.dart';

class AppColors {
  // Backgrounds
  static const Color background = Color(0xFF090D16);
  static const Color surface = Color(0xFF111726);
  static const Color surfaceHover = Color(0xFF182032);
  static const Color surfaceBorder = Color(0xFF1E293B);
  static const Color surfaceBorderActive = Color(0xFF334155);

  // Brand / Accents
  static const Color primary = Color(0xFF3B82F6);
  static const Color primaryGlow = Color(0x333B82F6);
  static const Color cyan = Color(0xFF06B6D4);
  static const Color purple = Color(0xFF8B5CF6);

  // Network Status / Latency Tiers
  static const Color latencyFast = Color(0xFF10B981);     // < 50ms (Green)
  static const Color latencyModerate = Color(0xFFF59E0B); // 50-130ms (Amber)
  static const Color latencySlow = Color(0xFFF97316);     // 130-220ms (Orange)
  static const Color latencyCritical = Color(0xFFEF4444); // > 220ms or Lost (Red)
  static const Color pending = Color(0xFF6B7280);

  // Text
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  static Color getLatencyColor(double rttMs, double lossRate) {
    if (rttMs < 0 || lossRate > 50) return latencyCritical;
    if (lossRate > 5 || rttMs > 200) return latencyCritical;
    if (rttMs > 130) return latencySlow;
    if (rttMs > 60) return latencyModerate;
    return latencyFast;
  }
}

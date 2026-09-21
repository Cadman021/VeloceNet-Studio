import 'package:flutter/material.dart';

/// Adaptive colors: dark cyber palette in dark mode, clean light palette
/// in light mode. Replaces direct `AppColors.surface/background/...`
/// uses so the theme toggle actually affects every screen.
extension ThemeX on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  Color get surfaceColor =>
      isDark ? const Color(0xFF111726) : Colors.white;
  Color get bgColor =>
      isDark ? const Color(0xFF090D16) : const Color(0xFFF1F5F9);
  Color get borderColor =>
      isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
  Color get textPrimaryColor =>
      isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
  Color get textSecondaryColor =>
      isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569);
  Color get textMutedColor =>
      isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
}

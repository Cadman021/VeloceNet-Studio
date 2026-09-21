import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide settings: theme mode + locale, persisted locally.
/// Default: English + System theme (per project decision).
class SettingsController extends ChangeNotifier {
  static const _kTheme = 'settings.themeMode';
  static const _kLocale = 'settings.locale';

  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = const Locale('en');

  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;

  bool get isDark => _themeMode == ThemeMode.dark;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final theme = prefs.getString(_kTheme);
      switch (theme) {
        case 'light':
          _themeMode = ThemeMode.light;
          break;
        case 'dark':
          _themeMode = ThemeMode.dark;
          break;
        default:
          _themeMode = ThemeMode.system;
      }
      final loc = prefs.getString(_kLocale);
      _locale = (loc == 'fa') ? const Locale('fa') : const Locale('en');
    } catch (_) {
      // Keep defaults on storage failure.
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kTheme,
        mode == ThemeMode.light ? 'light' : mode == ThemeMode.dark ? 'dark' : 'system',
      );
    } catch (_) {}
  }

  Future<void> setLocale(Locale locale) async {
    if (locale.languageCode != 'fa' && locale.languageCode != 'en') return;
    _locale = Locale(locale.languageCode);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLocale, _locale.languageCode);
    } catch (_) {}
  }
}

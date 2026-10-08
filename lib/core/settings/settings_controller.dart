import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide settings: theme mode + locale, persisted locally.
/// Default: English + System theme (per project decision).
class SettingsController extends ChangeNotifier {
  static const _kTheme = 'settings.themeMode';
  static const _kLocale = 'settings.locale';
  static const _kTgEnabled = 'settings.tgEnabled';
  static const _kTgToken = 'settings.tgToken';
  static const _kTgChat = 'settings.tgChat';
  static const _kDcEnabled = 'settings.dcEnabled';
  static const _kDcUrl = 'settings.dcUrl';

  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = const Locale('en');

  // Alert webhooks (Telegram bot + Discord webhook). Secrets persist in
  // plaintext alongside every other desktop preference — see the note on
  // WebhookDispatcher.
  bool telegramEnabled = false;
  String telegramToken = '';
  String telegramChatId = '';
  bool discordEnabled = false;
  String discordUrl = '';

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
      _locale = allowedLocales.contains(loc)
          ? Locale(loc!)
          : const Locale('en');
      telegramEnabled = prefs.getBool(_kTgEnabled) ?? false;
      telegramToken = prefs.getString(_kTgToken) ?? '';
      telegramChatId = prefs.getString(_kTgChat) ?? '';
      discordEnabled = prefs.getBool(_kDcEnabled) ?? false;
      discordUrl = prefs.getString(_kDcUrl) ?? '';
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

  Future<void> _saveWebhookPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTgEnabled, telegramEnabled);
      await prefs.setString(_kTgToken, telegramToken);
      await prefs.setString(_kTgChat, telegramChatId);
      await prefs.setBool(_kDcEnabled, discordEnabled);
      await prefs.setString(_kDcUrl, discordUrl);
    } catch (_) {}
  }

  Future<void> setTelegram(
      {bool? enabled, String? token, String? chatId}) async {
    if (enabled != null) telegramEnabled = enabled;
    if (token != null) telegramToken = token;
    if (chatId != null) telegramChatId = chatId;
    notifyListeners();
    await _saveWebhookPrefs();
  }

  Future<void> setDiscord({bool? enabled, String? url}) async {
    if (enabled != null) discordEnabled = enabled;
    if (url != null) discordUrl = url;
    notifyListeners();
    await _saveWebhookPrefs();
  }

  static const allowedLocales = ['en', 'fa', 'ru', 'zh'];

  Future<void> setLocale(Locale locale) async {
    if (!allowedLocales.contains(locale.languageCode)) return;
    _locale = Locale(locale.languageCode);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLocale, _locale.languageCode);
    } catch (_) {}
  }
}

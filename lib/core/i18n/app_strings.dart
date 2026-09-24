import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// JSON-backed localization (en/fa/ru/zh) loaded from `assets/lang/`.
///
/// Dictionaries live in one JSON file per language (`<code>.json`), NOT in
/// this file — see `test/i18n_parity_test.dart`, which enforces identical
/// key sets across all four files. Default locale is English.
///
/// Lifecycle: call [ensureLoaded] once at startup (see `main()`); the
/// synchronous [get] API then works everywhere. Before loading, [get]
/// falls back to the key itself; missing keys fall back to English.
class AppStrings {
  static const List<String> languageCodes = ['en', 'fa', 'ru', 'zh'];

  static const supportedLocales = [
    Locale('en'),
    Locale('fa'),
    Locale('ru'),
    Locale('zh'),
  ];

  static final Map<String, Map<String, String>> _tables = {};
  static bool get isLoaded => _tables.isNotEmpty;

  static Future<void> ensureLoaded({AssetBundle? bundle}) async {
    if (_tables.isNotEmpty) return;
    final b = bundle ?? rootBundle;
    for (final code in languageCodes) {
      try {
        final raw = await b.loadString('assets/lang/$code.json');
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _tables[code] =
            decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {
        _tables[code] = {};
      }
    }
    _tables.putIfAbsent('en', () => {});
  }

  /// Synchronous test/seed hook (bypasses asset loading).
  @visibleForTesting
  static void seedForTesting(Map<String, Map<String, String>> tables) {
    _tables
      ..clear()
      ..addAll(tables);
  }

  final Locale locale;
  const AppStrings(this.locale);

  bool get isFa => locale.languageCode == 'fa';

  /// True for right-to-left locales (currently only Persian).
  bool get isRtl => isFa;

  String get(String key) =>
      _tables[locale.languageCode]?[key] ??
      _tables['en']?[key] ??
      key;

  static AppStrings of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return AppStrings(locale);
  }
}

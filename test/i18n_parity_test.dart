import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the JSON dictionaries in `assets/lang/`: every language must
/// expose exactly the same key set, so no locale can ship half-translated.
/// (Pure dart:io test — no Flutter binding needed.)
void main() {
  test('all language JSONs share identical key sets', () async {
    const codes = ['en', 'fa', 'ru', 'zh'];
    final tables = <String, Set<String>>{};
    for (final code in codes) {
      final file = File('assets/lang/$code.json');
      expect(await file.exists(), isTrue, reason: 'missing $code.json');
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(decoded.isNotEmpty, isTrue, reason: '$code.json is empty');
      for (final entry in decoded.entries) {
        expect(entry.value, isA<String>(), reason: '$code.${entry.key}');
        expect((entry.value as String).isNotEmpty, isTrue,
            reason: '$code.${entry.key} is empty');
      }
      tables[code] = decoded.keys.toSet();
    }
    for (final code in ['fa', 'ru', 'zh']) {
      expect(
        tables[code],
        tables['en'],
        reason: 'key mismatch between en and $code',
      );
    }
  });
}

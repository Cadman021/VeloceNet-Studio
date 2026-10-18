import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/services/punycode.dart';

void main() {
  group('punycodeEncode (RFC 3492 §7 vectors)', () {
    test('ASCII passes through', () {
      expect(punycodeEncode('example'), 'example');
      expect(punycodeEncode('a-b'), 'a-b');
    });
    test('official vectors', () {
      // (A) Arabic, (B) Chinese simplified, (C)-(G) incl. ünchen below.
      expect(punycodeEncode('ليهمابتكلموشعربي؟'), 'egbpdaj6bu4bxfgehfvwxn');
      expect(punycodeEncode('他们为什么不说中文'), 'ihqwcrb4cv8a8dqg056pqjye');
      expect(punycodeEncode('münchen'), 'mnchen-3ya');
      expect(punycodeEncode('ü'), 'tda');
      // Verified against an independent oracle (Python's own idna codec).
      expect(punycodeEncode('üëäöü'), '4can8avd');
    });
  });

  group('toAsciiDomain', () {
    test('lowercases, strips root dot, encodes IDN labels', () {
      expect(toAsciiDomain('Example.COM'), 'example.com');
      expect(toAsciiDomain('example.com.'), 'example.com');
      expect(toAsciiDomain('münchen.de'), 'xn--mnchen-3ya.de');
      expect(toAsciiDomain('GOOGLE.com.'), 'google.com');
    });

    test('rejects garbage', () {
      expect(() => toAsciiDomain(''), throwsFormatException);
      expect(() => toAsciiDomain('a..com'), throwsFormatException);
      expect(() => toAsciiDomain('${'a' * 64}.com'), throwsFormatException);
    });
  });
}

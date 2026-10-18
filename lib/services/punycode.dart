/// Minimal Punycode encoder (RFC 3492) for IDNA ToASCII.
///
/// Why hand-rolled: no `idna` package exists on pub.dev, and pulling a
/// dependency for one pure function is unjustified. Scope is deliberately
/// narrow — lowercase + per-label `xn--` encoding, no UTS46 mapping or
/// validation. ASCII labels pass through untouched; garbage-in produces
/// *something* deterministic but callers must validate beforehand
/// ([normalizeTraceHost] already does).
library;

/// Encodes one domain label to Punycode (`münchen` → `mnchen-3ya`).
/// Pure ASCII labels (including hyphens) are returned unchanged.
String punycodeEncode(String label) {
  final input = label.runes.toList();
  if (input.every((c) => c < 0x80)) return label;

  const base = 36;
  const tmin = 1;
  const tmax = 26;
  const skew = 38;
  const damp = 700;
  const initialBias = 72;
  const initialN = 128;

  String encodeDigit(int d) => String.fromCharCode(d + (d < 26 ? 97 : 22));

  int adapt(int delta, int numPoints, bool firstTime) {
    delta = firstTime ? (delta ~/ damp) : (delta >> 1);
    delta += delta ~/ numPoints;
    var k = 0;
    while (delta > ((base - tmin) * tmax) ~/ 2) {
      delta ~/= base - tmin;
      k += base;
    }
    return k + (((base - tmin + 1) * delta) ~/ (delta + skew));
  }

  final output = StringBuffer();
  final basic = input.where((c) => c < 0x80).toList();
  for (final c in basic) {
    output.writeCharCode(c);
  }
  var handled = basic.length;
  var n = initialN;
  var delta = 0;
  var bias = initialBias;
  if (basic.isNotEmpty) output.write('-');

  while (handled < input.length) {
    var m = 0x7FFFFFFF;
    for (final c in input) {
      if (c >= n && c < m) m = c;
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final c in input) {
      if (c < n) {
        delta++;
      } else if (c == n) {
        var q = delta;
        var k = base;
        while (true) {
          final t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias);
          if (q < t) break;
          output.write(encodeDigit(t + (q - t) % (base - t)));
          q = (q - t) ~/ (base - t);
          k += base;
        }
        output.write(encodeDigit(q));
        bias = adapt(delta, handled + 1, handled == basic.length);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return output.toString();
}

/// Converts a human domain to ASCII wire form: lowercases, strips one
/// trailing root dot (`example.com.` is a valid FQDN), and `xn--` encodes
/// non-ASCII labels. Throws [FormatException] on empty/oversized labels.
String toAsciiDomain(String domain) {
  var s = domain.trim().toLowerCase();
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  if (s.isEmpty) throw const FormatException('empty domain');
  final out = <String>[];
  for (final label in s.split('.')) {
    if (label.isEmpty || label.length > 63) {
      throw FormatException('bad label: $label');
    }
    final needsEncode = label.runes.any((c) => c >= 0x80);
    out.add(needsEncode ? 'xn--${punycodeEncode(label)}' : label);
  }
  final joined = out.join('.');
  if (joined.length > 253) throw const FormatException('domain too long');
  return joined;
}

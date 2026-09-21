/// Known Cloudflare Warp / WARP+ endpoint ranges and ports.
///
/// Sources: public Warp scanner projects (e.g. warp-scanner communities).
/// Ranges are user-selectable; ports are the UDP ports Warp listens on.
class WarpCatalog {
  WarpCatalog._();

  static const List<WarpRange> ranges = [
    WarpRange(
      id: 'main-162',
      label: '162.159.192.0/24',
      labelFa: 'بازه اصلی اول',
      base: '162.159.192',
      from: 0,
      to: 255,
    ),
    WarpRange(
      id: 'main-188',
      label: '188.114.96.0/24',
      labelFa: 'بازه اصلی دوم',
      base: '188.114.96',
      from: 0,
      to: 255,
    ),
    WarpRange(
      id: 'extra-162-193',
      label: '162.159.193.0/24',
      labelFa: 'بازه فرعی اول',
      base: '162.159.193',
      from: 0,
      to: 255,
    ),
    WarpRange(
      id: 'extra-188-97',
      label: '188.114.97.0/24',
      labelFa: 'بازه فرعی دوم',
      base: '188.114.97',
      from: 0,
      to: 255,
    ),
  ];

  /// Commonly used Warp UDP ports (plus a few extras users asked for).
  static const List<int> ports = [
    500,
    854,
    859,
    864,
    878,
    890,
    908,
    928,
    946,
    955,
    968,
    988,
    1002,
    1010,
    1014,
    1024,
    1074,
    1701,
    2408,
    3138,
    3476,
    4500,
  ];

  static const int defaultPort = 864;
}

class WarpRange {
  final String id;
  final String label;
  final String labelFa;
  final String base;
  final int from;
  final int to;

  const WarpRange({
    required this.id,
    required this.label,
    this.labelFa = '',
    required this.base,
    required this.from,
    required this.to,
  });

  /// Localized display name: CIDR plus a short fa/en qualifier.
  String displayName(bool isFa) =>
      labelFa.isNotEmpty && isFa ? '$label ($labelFa)' : label;

  int get size => to - from + 1;

  /// Expands to ip strings: base.from ... base.to
  List<String> expandIps() {
    final out = <String>[];
    for (int i = from; i <= to; i++) {
      out.add('$base.$i');
    }
    return out;
  }
}

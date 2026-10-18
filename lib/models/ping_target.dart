enum NetworkProtocol {
  icmp(0, 'ICMP'),
  tcp(1, 'TCP'),
  http(2, 'HTTP'),
  https(3, 'HTTPS');

  final int id;
  final String label;
  const NetworkProtocol(this.id, this.label);

  bool get isHttp =>
      this == NetworkProtocol.http || this == NetworkProtocol.https;

  int get defaultPort => this == NetworkProtocol.https ? 443 : 80;

  static NetworkProtocol fromId(int id) {
    return NetworkProtocol.values.firstWhere(
      (e) => e.id == id,
      orElse: () => NetworkProtocol.icmp,
    );
  }
}

class PingTarget {
  static const int maxGroupLength = 40;
  static const int maxTagLength = 24;
  static const int maxTags = 8;
  static const int maxHttpPathLength = 256;

  final int id;
  final String name;
  final String host;
  final int port;
  final NetworkProtocol protocol;
  // Request path for HTTP(S) probes (e.g. "/health"). Empty means "/".
  // Ignored by ICMP/TCP.
  final String httpPath;
  final int intervalMs;
  final int timeoutMs;
  final bool isEnabled;
  // Muted targets keep probing (metrics stay live) but never emit alert
  // events — the lightweight maintenance-window primitive.
  final bool muted;
  // Optional grouping: one free-form group label per target...
  final String? group;
  // ...plus any number of free-form tags (used for filtering/grouping in
  // the matrix). Both are sanitized on every read/write path.
  final List<String> tags;

  const PingTarget({
    required this.id,
    required this.name,
    required this.host,
    this.port = 80,
    this.protocol = NetworkProtocol.icmp,
    this.httpPath = '',
    this.intervalMs = 1000,
    this.timeoutMs = 1500,
    this.isEnabled = true,
    this.muted = false,
    this.group,
    this.tags = const [],
  });

  /// Normalizes a user-typed HTTP path: trims, strips control characters,
  /// ensures a leading "/" and caps the length. Empty stays empty (= "/").
  static String sanitizeHttpPath(String? raw) {
    var path = raw?.trim() ?? '';
    if (path.isEmpty) return '';
    path = path.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    if (!path.startsWith('/')) path = '/$path';
    if (path.length > maxHttpPathLength) {
      path = path.substring(0, maxHttpPathLength);
    }
    return path;
  }

  /// Trims + length-caps a user-typed group label. Empty → null.
  static String? sanitizeGroup(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed.length > maxGroupLength
        ? trimmed.substring(0, maxGroupLength)
        : trimmed;
  }

  /// Trims, length-caps, dedupes (case-insensitive, first spelling wins)
  /// and count-caps a tag list. Order is preserved.
  static List<String> sanitizeTags(Iterable<String> raw) {
    final out = <String>[];
    final seen = <String>{};
    for (var tag in raw) {
      tag = tag.trim();
      if (tag.isEmpty) continue;
      if (tag.length > maxTagLength) tag = tag.substring(0, maxTagLength);
      if (!seen.add(tag.toLowerCase())) continue;
      out.add(tag);
      if (out.length >= maxTags) break;
    }
    return out;
  }

  /// Parses a tags value from JSON: a list of strings, or a single
  /// comma-separated string (hand-written backups).
  static List<String> parseTags(dynamic raw) {
    if (raw is List) {
      return sanitizeTags(raw.map((e) => e?.toString() ?? ''));
    }
    if (raw is String) {
      return sanitizeTags(raw.split(RegExp(r'[,،]')));
    }
    return const [];
  }

  PingTarget copyWith({
    int? id,
    String? name,
    String? host,
    int? port,
    NetworkProtocol? protocol,
    String? httpPath,
    int? intervalMs,
    int? timeoutMs,
    bool? isEnabled,
    bool? muted,
    Object? group = _unset,
    List<String>? tags,
  }) {
    return PingTarget(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      httpPath: httpPath == null ? this.httpPath : sanitizeHttpPath(httpPath),
      intervalMs: intervalMs ?? this.intervalMs,
      timeoutMs: timeoutMs ?? this.timeoutMs,
      isEnabled: isEnabled ?? this.isEnabled,
      muted: muted ?? this.muted,
      group: identical(group, _unset)
          ? this.group
          : sanitizeGroup(group as String?),
      tags: tags ?? this.tags,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'protocol': protocol.id,
        'http_path': httpPath,
        'interval_ms': intervalMs,
        'timeout_ms': timeoutMs,
        'is_enabled': isEnabled,
        'is_muted': muted,
        'group': group,
        'tags': tags,
      };

  factory PingTarget.fromJson(Map<String, dynamic> json) => PingTarget(
        id: json['id'] as int,
        name: json['name'] as String,
        host: json['host'] as String,
        port: (json['port'] as int?) ?? 80,
        protocol: NetworkProtocol.fromId((json['protocol'] as int?) ?? 0),
        httpPath: sanitizeHttpPath(json['http_path']?.toString()),
        intervalMs: (json['interval_ms'] as int?) ?? 1000,
        timeoutMs: (json['timeout_ms'] as int?) ?? 1500,
        isEnabled: (json['is_enabled'] as bool?) ?? true,
        muted: (json['is_muted'] as bool?) ?? false,
        group: sanitizeGroup(json['group']?.toString()),
        tags: parseTags(json['tags']),
      );
}

const Object _unset = Object();

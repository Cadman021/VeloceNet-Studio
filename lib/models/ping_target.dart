enum NetworkProtocol {
  icmp(0, 'ICMP'),
  tcp(1, 'TCP');

  final int id;
  final String label;
  const NetworkProtocol(this.id, this.label);

  static NetworkProtocol fromId(int id) {
    return NetworkProtocol.values.firstWhere(
      (e) => e.id == id,
      orElse: () => NetworkProtocol.icmp,
    );
  }
}

class PingTarget {
  final int id;
  final String name;
  final String host;
  final int port;
  final NetworkProtocol protocol;
  final int intervalMs;
  final int timeoutMs;
  final bool isEnabled;

  const PingTarget({
    required this.id,
    required this.name,
    required this.host,
    this.port = 80,
    this.protocol = NetworkProtocol.icmp,
    this.intervalMs = 1000,
    this.timeoutMs = 1500,
    this.isEnabled = true,
  });

  PingTarget copyWith({
    int? id,
    String? name,
    String? host,
    int? port,
    NetworkProtocol? protocol,
    int? intervalMs,
    int? timeoutMs,
    bool? isEnabled,
  }) {
    return PingTarget(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      intervalMs: intervalMs ?? this.intervalMs,
      timeoutMs: timeoutMs ?? this.timeoutMs,
      isEnabled: isEnabled ?? this.isEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'protocol': protocol.id,
        'interval_ms': intervalMs,
        'timeout_ms': timeoutMs,
        'is_enabled': isEnabled,
      };

  factory PingTarget.fromJson(Map<String, dynamic> json) => PingTarget(
        id: json['id'] as int,
        name: json['name'] as String,
        host: json['host'] as String,
        port: (json['port'] as int?) ?? 80,
        protocol: NetworkProtocol.fromId((json['protocol'] as int?) ?? 0),
        intervalMs: (json['interval_ms'] as int?) ?? 1000,
        timeoutMs: (json['timeout_ms'] as int?) ?? 1500,
        isEnabled: (json['is_enabled'] as bool?) ?? true,
      );
}

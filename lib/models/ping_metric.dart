enum TargetStatus {
  pending,
  online,
  degraded,
  offline;

  static TargetStatus fromString(String val) {
    switch (val.toLowerCase()) {
      case 'online':
        return TargetStatus.online;
      case 'degraded':
        return TargetStatus.degraded;
      case 'offline':
        return TargetStatus.offline;
      default:
        return TargetStatus.pending;
    }
  }
}

class PingMetric {
  final int id;
  final String name;
  final String host;
  final int port;
  final String protocol;
  final TargetStatus status;
  final int sentCount;
  final int receivedCount;
  final int lostCount;
  final double lossRate;
  final double lastRttMs;
  final double minRttMs;
  final double maxRttMs;
  final double avgRttMs;
  final double jitterMs;
  final List<double> history;
  final int lastCheckedEpochMs;

  const PingMetric({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.protocol,
    required this.status,
    required this.sentCount,
    required this.receivedCount,
    required this.lostCount,
    required this.lossRate,
    required this.lastRttMs,
    required this.minRttMs,
    required this.maxRttMs,
    required this.avgRttMs,
    required this.jitterMs,
    required this.history,
    required this.lastCheckedEpochMs,
  });

  factory PingMetric.initial(int id, String name, String host, int port, String protocol) {
    return PingMetric(
      id: id,
      name: name,
      host: host,
      port: port,
      protocol: protocol,
      status: TargetStatus.pending,
      sentCount: 0,
      receivedCount: 0,
      lostCount: 0,
      lossRate: 0.0,
      lastRttMs: 0.0,
      minRttMs: 0.0,
      maxRttMs: 0.0,
      avgRttMs: 0.0,
      jitterMs: 0.0,
      history: const [],
      lastCheckedEpochMs: 0,
    );
  }

  factory PingMetric.fromJson(Map<String, dynamic> json) {
    final historyList = (json['history'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [];

    return PingMetric(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? '',
      port: (json['port'] as int?) ?? 80,
      protocol: json['protocol'] as String? ?? 'ICMP',
      status: TargetStatus.fromString(json['status'] as String? ?? 'Pending'),
      sentCount: (json['sent_count'] as num?)?.toInt() ?? 0,
      receivedCount: (json['received_count'] as num?)?.toInt() ?? 0,
      lostCount: (json['lost_count'] as num?)?.toInt() ?? 0,
      lossRate: (json['loss_rate'] as num?)?.toDouble() ?? 0.0,
      lastRttMs: (json['last_rtt_ms'] as num?)?.toDouble() ?? 0.0,
      minRttMs: (json['min_rtt_ms'] as num?)?.toDouble() ?? 0.0,
      maxRttMs: (json['max_rtt_ms'] as num?)?.toDouble() ?? 0.0,
      avgRttMs: (json['avg_rtt_ms'] as num?)?.toDouble() ?? 0.0,
      jitterMs: (json['jitter_ms'] as num?)?.toDouble() ?? 0.0,
      history: historyList,
      lastCheckedEpochMs: (json['last_checked_epoch_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

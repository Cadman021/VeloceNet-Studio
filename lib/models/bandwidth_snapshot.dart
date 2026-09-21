class InterfaceStat {
  final String name;
  final String alias;
  final double upBps;
  final double downBps;
  final double totalBps;
  final int speedBps;
  final bool isUp;

  const InterfaceStat({
    required this.name,
    required this.alias,
    required this.upBps,
    required this.downBps,
    required this.totalBps,
    required this.speedBps,
    required this.isUp,
  });

  factory InterfaceStat.fromJson(Map<String, dynamic> json) {
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    return InterfaceStat(
      name: json['name'] as String? ?? '',
      alias: json['alias'] as String? ?? '',
      upBps: d(json['upBps']),
      downBps: d(json['downBps']),
      totalBps: d(json['totalBps']),
      speedBps: (json['speedBps'] as num?)?.toInt() ?? 0,
      isUp: json['isUp'] as bool? ?? true,
    );
  }
}

class ProcessTraffic {
  final int pid;
  final String name;
  final String protocol;
  final double upBps;
  final double downBps;
  final double totalBps;
  final int connections;

  const ProcessTraffic({
    required this.pid,
    required this.name,
    required this.protocol,
    required this.upBps,
    required this.downBps,
    required this.totalBps,
    required this.connections,
  });

  factory ProcessTraffic.fromJson(Map<String, dynamic> json) {
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    return ProcessTraffic(
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      protocol: json['protocol'] as String? ?? '',
      upBps: d(json['upBps']),
      downBps: d(json['downBps']),
      totalBps: d(json['totalBps']),
      connections: (json['connections'] as num?)?.toInt() ?? 0,
    );
  }
}

class BandwidthSnapshot {
  final int timestampMs;
  final double upBps;
  final double downBps;
  final double totalBps;
  final List<InterfaceStat> interfaces;
  final List<ProcessTraffic> topProcesses;
  final bool isEstimated;
  final String? note;

  const BandwidthSnapshot({
    required this.timestampMs,
    required this.upBps,
    required this.downBps,
    required this.totalBps,
    required this.interfaces,
    required this.topProcesses,
    required this.isEstimated,
    this.note,
  });

  factory BandwidthSnapshot.empty() {
    return const BandwidthSnapshot(
      timestampMs: 0,
      upBps: 0,
      downBps: 0,
      totalBps: 0,
      interfaces: [],
      topProcesses: [],
      isEstimated: true,
      note: 'not started',
    );
  }

  factory BandwidthSnapshot.fromJson(Map<String, dynamic> json) {
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    final ifaces = (json['interfaces'] as List<dynamic>?)
            ?.map((e) => InterfaceStat.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <InterfaceStat>[];
    final procs = (json['topProcesses'] as List<dynamic>?)
            ?.map((e) => ProcessTraffic.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <ProcessTraffic>[];
    return BandwidthSnapshot(
      timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
      upBps: d(json['upBps']),
      downBps: d(json['downBps']),
      totalBps: d(json['totalBps']),
      interfaces: ifaces,
      topProcesses: procs,
      isEstimated: json['isEstimated'] as bool? ?? false,
      note: json['note'] as String?,
    );
  }
}

/// Formats a bits-per-second rate as a human string, e.g. 12.4 Mbps.
String formatRate(double bps) {
  if (bps < 1000) return '${bps.toStringAsFixed(0)} bps';
  if (bps < 1000000) return '${(bps / 1000).toStringAsFixed(1)} Kbps';
  if (bps < 1000000000) return '${(bps / 1000000).toStringAsFixed(2)} Mbps';
  return '${(bps / 1000000000).toStringAsFixed(2)} Gbps';
}

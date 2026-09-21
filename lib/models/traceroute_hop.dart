class TracerouteHop {
  final int hopNum;
  final String ip;
  final String? hostname;
  final double rttMs;
  final bool isTimeout;
  final bool reachedDestination;
  final String status;

  const TracerouteHop({
    required this.hopNum,
    required this.ip,
    this.hostname,
    required this.rttMs,
    required this.isTimeout,
    required this.reachedDestination,
    required this.status,
  });

  factory TracerouteHop.fromJson(Map<String, dynamic> json) {
    return TracerouteHop(
      hopNum: (json['hopNum'] as num).toInt(),
      ip: json['ip'] as String? ?? '*',
      hostname: json['hostname'] as String?,
      rttMs: (json['rttMs'] as num).toDouble(),
      isTimeout: json['isTimeout'] as bool? ?? false,
      reachedDestination: json['reachedDestination'] as bool? ?? false,
      status: json['status'] as String? ?? '',
    );
  }
}

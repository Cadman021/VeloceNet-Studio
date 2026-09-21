import 'traceroute_hop.dart';

class TracerouteProgress {
  final int sessionId;
  final String targetHost;
  final String targetIp;
  final int maxHops;
  final int currentHop;
  final bool isRunning;
  final bool isCompleted;
  final String? error;
  final List<TracerouteHop> hops;

  const TracerouteProgress({
    required this.sessionId,
    required this.targetHost,
    required this.targetIp,
    required this.maxHops,
    required this.currentHop,
    required this.isRunning,
    required this.isCompleted,
    this.error,
    required this.hops,
  });

  factory TracerouteProgress.initial(String host) {
    return TracerouteProgress(
      sessionId: 0,
      targetHost: host,
      targetIp: '',
      maxHops: 30,
      currentHop: 0,
      isRunning: false,
      isCompleted: false,
      hops: const [],
    );
  }

  factory TracerouteProgress.fromJson(Map<String, dynamic> json) {
    final hopsList = (json['hops'] as List<dynamic>?)
            ?.map((e) => TracerouteHop.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];

    return TracerouteProgress(
      sessionId: (json['sessionId'] as num?)?.toInt() ?? 0,
      targetHost: json['targetHost'] as String? ?? '',
      targetIp: json['targetIp'] as String? ?? '',
      maxHops: (json['maxHops'] as num?)?.toInt() ?? 30,
      currentHop: (json['currentHop'] as num?)?.toInt() ?? 0,
      isRunning: json['isRunning'] as bool? ?? false,
      isCompleted: json['isCompleted'] as bool? ?? false,
      error: json['error'] as String?,
      hops: hopsList,
    );
  }

  TracerouteProgress copyWith({
    int? sessionId,
    String? targetHost,
    String? targetIp,
    int? maxHops,
    int? currentHop,
    bool? isRunning,
    bool? isCompleted,
    String? error,
    List<TracerouteHop>? hops,
  }) {
    return TracerouteProgress(
      sessionId: sessionId ?? this.sessionId,
      targetHost: targetHost ?? this.targetHost,
      targetIp: targetIp ?? this.targetIp,
      maxHops: maxHops ?? this.maxHops,
      currentHop: currentHop ?? this.currentHop,
      isRunning: isRunning ?? this.isRunning,
      isCompleted: isCompleted ?? this.isCompleted,
      error: error ?? this.error,
      hops: hops ?? this.hops,
    );
  }
}

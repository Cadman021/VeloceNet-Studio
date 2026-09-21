class WarpResult {
  final String ip;
  final int port;
  final String endpoint;
  final double rttMs;
  final bool success;
  final String? note;

  const WarpResult({
    required this.ip,
    required this.port,
    required this.endpoint,
    required this.rttMs,
    required this.success,
    this.note,
  });

  factory WarpResult.fromJson(Map<String, dynamic> json) {
    return WarpResult(
      ip: json['ip'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      endpoint: json['endpoint'] as String? ?? '',
      rttMs: (json['rttMs'] as num?)?.toDouble() ?? -1.0,
      success: json['success'] as bool? ?? false,
      note: json['error'] as String?,
    );
  }

  bool get viaTcpFallback => note?.contains('TCP fallback') ?? false;
}

class WarpProgress {
  final int sessionId;
  final int total;
  final int tested;
  final int succeeded;
  final int failed;
  final bool isRunning;
  final bool isCompleted;
  final String? error;
  final List<WarpResult> results;

  const WarpProgress({
    required this.sessionId,
    required this.total,
    required this.tested,
    required this.succeeded,
    required this.failed,
    required this.isRunning,
    required this.isCompleted,
    this.error,
    required this.results,
  });

  factory WarpProgress.empty() {
    return const WarpProgress(
      sessionId: 0,
      total: 0,
      tested: 0,
      succeeded: 0,
      failed: 0,
      isRunning: false,
      isCompleted: false,
      results: [],
    );
  }

  factory WarpProgress.fromJson(Map<String, dynamic> json) {
    final list = (json['results'] as List<dynamic>?)
            ?.map((e) => WarpResult.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <WarpResult>[];
    return WarpProgress(
      sessionId: (json['sessionId'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      tested: (json['tested'] as num?)?.toInt() ?? 0,
      succeeded: (json['succeeded'] as num?)?.toInt() ?? 0,
      failed: (json['failed'] as num?)?.toInt() ?? 0,
      isRunning: json['isRunning'] as bool? ?? false,
      isCompleted: json['isCompleted'] as bool? ?? false,
      error: json['error'] as String?,
      results: list,
    );
  }

  /// Successful results sorted fastest-first.
  List<WarpResult> get ranked {
    final ok = results.where((r) => r.success).toList()
      ..sort((a, b) => a.rttMs.compareTo(b.rttMs));
    return ok;
  }
}

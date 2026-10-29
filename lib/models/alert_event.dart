import 'ping_metric.dart';

/// Severity of a status transition, derived from the *destination* status.
enum AlertSeverity { info, warning, critical }

/// One recorded status transition of a monitored target.
class AlertEvent {
  final int id;
  final int targetId;
  final String targetName;
  final TargetStatus from;
  final TargetStatus to;
  final DateTime timestamp;
  final double rttMs;
  final double lossRate;

  const AlertEvent({
    required this.id,
    required this.targetId,
    required this.targetName,
    required this.from,
    required this.to,
    required this.timestamp,
    required this.rttMs,
    required this.lossRate,
  });

  AlertSeverity get severity {
    switch (to) {
      case TargetStatus.offline:
        return AlertSeverity.critical;
      case TargetStatus.degraded:
        return AlertSeverity.warning;
      case TargetStatus.online:
      case TargetStatus.pending:
        return AlertSeverity.info;
    }
  }

  /// Machine-readable envelope for generic webhook receivers: stable enum
  /// names (not localized labels) plus the raw metrics, so a receiver can
  /// branch on severity/transition without parsing the human message.
  Map<String, String> toJson() => {
        'id': '$id',
        'targetId': '$targetId',
        'targetName': targetName,
        'from': from.name,
        'to': to.name,
        'severity': severity.name,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'rttMs': rttMs > 0 ? rttMs.toStringAsFixed(1) : '',
        'lossRate': lossRate > 0 ? lossRate.toStringAsFixed(1) : '',
      };
}

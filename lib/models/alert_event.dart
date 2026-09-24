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
}

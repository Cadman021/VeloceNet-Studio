import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/alert_event.dart';
import 'package:netstudio/models/ping_metric.dart';
import 'package:netstudio/state/alert_log.dart';

AlertEvent? record(
  AlertLog log,
  TargetStatus from,
  TargetStatus to,
) {
  return log.noteTransition(
    targetId: 1,
    targetName: 't',
    from: from,
    to: to,
    rttMs: 10.0,
    lossRate: 0.0,
  );
}

void main() {
  group('AlertLog', () {
    test('records transitions, newest first', () {
      final log = AlertLog();
      record(log, TargetStatus.online, TargetStatus.degraded);
      record(log, TargetStatus.degraded, TargetStatus.offline);
      expect(log.events, hasLength(2));
      expect(log.events.first.to, TargetStatus.offline);
      expect(log.events.first.severity, AlertSeverity.critical);
      expect(log.unreadCount, 2);
    });

    test('ignores no-change and pending baseline', () {
      final log = AlertLog();
      expect(record(log, TargetStatus.online, TargetStatus.online), isNull);
      // Boot baseline: pending -> online is not an alert.
      expect(record(log, TargetStatus.pending, TargetStatus.online), isNull);
      expect(log.isEmpty, isTrue);
      expect(log.unreadCount, 0);
    });

    test('recovery is info severity', () {
      final log = AlertLog();
      final e = record(log, TargetStatus.offline, TargetStatus.online)!;
      expect(e.severity, AlertSeverity.info);
    });

    test('caps at maxEvents and tracks read state', () {
      final log = AlertLog();
      for (int i = 0; i < AlertLog.maxEvents + 10; i++) {
        record(log, TargetStatus.online, TargetStatus.degraded);
      }
      expect(log.events, hasLength(AlertLog.maxEvents));
      expect(log.unreadCount, AlertLog.maxEvents + 10);
      log.markAllRead();
      expect(log.unreadCount, 0);
      log.clear();
      expect(log.isEmpty, isTrue);
    });
  });
}

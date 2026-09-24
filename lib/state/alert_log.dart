import 'package:flutter/foundation.dart';
import '../models/alert_event.dart';
import '../models/ping_metric.dart';

/// In-memory log of target status transitions (newest first).
///
/// Rules:
/// - Transitions *from* `pending` are ignored: they are the initial
///   baseline when monitoring starts, not real events (otherwise every
///   target would emit a fake "recovery" at boot).
/// - No-change updates are ignored.
/// - The log is capped at [maxEvents]; oldest events are evicted.
/// - History survives `resetMetrics` (it is history, not live state).
class AlertLog extends ChangeNotifier {
  static const int maxEvents = 200;

  final List<AlertEvent> _events = [];
  int _nextId = 1;
  int _unread = 0;

  List<AlertEvent> get events => List.unmodifiable(_events);
  int get unreadCount => _unread;
  bool get isEmpty => _events.isEmpty;

  /// Records a transition; returns the event, or null when ignored.
  AlertEvent? noteTransition({
    required int targetId,
    required String targetName,
    required TargetStatus from,
    required TargetStatus to,
    required double rttMs,
    required double lossRate,
    DateTime? at,
  }) {
    if (from == to || from == TargetStatus.pending) return null;
    final event = AlertEvent(
      id: _nextId++,
      targetId: targetId,
      targetName: targetName,
      from: from,
      to: to,
      timestamp: at ?? DateTime.now(),
      rttMs: rttMs,
      lossRate: lossRate,
    );
    _events.insert(0, event);
    if (_events.length > maxEvents) {
      _events.removeRange(maxEvents, _events.length);
    }
    _unread++;
    notifyListeners();
    return event;
  }

  void markAllRead() {
    if (_unread == 0) return;
    _unread = 0;
    notifyListeners();
  }

  void clear() {
    if (_events.isEmpty && _unread == 0) return;
    _events.clear();
    _unread = 0;
    notifyListeners();
  }
}

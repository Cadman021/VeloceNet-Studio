import 'traceroute_hop.dart';

/// One hop-level difference between two traces of the same target.
class RouteHopDelta {
  final int hopNum;
  final String? beforeIp;
  final String? afterIp;

  /// 'added' | 'removed' | 'changed' | 'unchanged'
  final String kind;

  const RouteHopDelta({
    required this.hopNum,
    required this.beforeIp,
    required this.afterIp,
    required this.kind,
  });

  bool get isChange => kind != 'unchanged';
}

/// Diff between a previous and a current trace of the same target.
///
/// Timeout hops (`*`) never count as a route change: a router that stops
/// answering ICMP is a visibility loss, not a path change, and treating it
/// as one would flap on every rate-limited hop.
class RouteDiff {
  final List<RouteHopDelta> deltas;
  final int changedCount;
  final int addedCount;
  final int removedCount;

  const RouteDiff({
    required this.deltas,
    required this.changedCount,
    required this.addedCount,
    required this.removedCount,
  });

  bool get hasChanges => changedCount + addedCount + removedCount > 0;

  static const RouteDiff empty = RouteDiff(
    deltas: [],
    changedCount: 0,
    addedCount: 0,
    removedCount: 0,
  );

  /// Diffs [previous] against [current] by hop number.
  ///
  /// Pure and I/O-free so the comparison rules are unit-testable without a
  /// live network. Hops are matched positionally by [TracerouteHop.hopNum].
  static RouteDiff between(
    List<TracerouteHop> previous,
    List<TracerouteHop> current,
  ) {
    if (previous.isEmpty || current.isEmpty) return empty;

    final prevByNum = <int, TracerouteHop>{
      for (final h in previous) h.hopNum: h,
    };
    final currByNum = <int, TracerouteHop>{
      for (final h in current) h.hopNum: h,
    };

    final nums = <int>{...prevByNum.keys, ...currByNum.keys}.toList()..sort();

    final deltas = <RouteHopDelta>[];
    var changed = 0, added = 0, removed = 0;

    for (final n in nums) {
      final before = prevByNum[n];
      final after = currByNum[n];

      String? beforeIp = _liveIp(before);
      String? afterIp = _liveIp(after);

      String kind;
      if (beforeIp != null && afterIp != null) {
        kind = beforeIp == afterIp ? 'unchanged' : 'changed';
      } else if (beforeIp == null && afterIp != null) {
        // Timeout -> responding, or this hop number is newly visible.
        kind = 'added';
      } else if (beforeIp != null && afterIp == null) {
        kind = 'removed';
      } else {
        kind = 'unchanged'; // both timeouts
      }

      switch (kind) {
        case 'changed':
          changed++;
        case 'added':
          added++;
        case 'removed':
          removed++;
      }

      deltas.add(RouteHopDelta(
        hopNum: n,
        beforeIp: beforeIp,
        afterIp: afterIp,
        kind: kind,
      ));
    }

    return RouteDiff(
      deltas: deltas,
      changedCount: changed,
      addedCount: added,
      removedCount: removed,
    );
  }

  /// The IP worth comparing, or null when the hop is a timeout / no reply.
  static String? _liveIp(TracerouteHop? hop) {
    if (hop == null || hop.isTimeout || hop.ip == '*') return null;
    return hop.ip;
  }
}

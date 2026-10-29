import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/route_change.dart';
import 'package:netstudio/models/traceroute_hop.dart';

TracerouteHop _hop(int n, String ip, {bool timeout = false}) {
  return TracerouteHop(
    hopNum: n,
    ip: ip,
    rttMs: timeout ? -1.0 : 10.0,
    isTimeout: timeout,
    reachedDestination: false,
    status: timeout ? 'Request Timed Out' : 'Time Exceeded in Transit',
  );
}

void main() {
  group('RouteDiff.between', () {
    test('identical paths report no changes', () {
      final path = [_hop(1, '10.0.0.1'), _hop(2, '10.0.0.2')];
      final diff = RouteDiff.between(path, path);
      expect(diff.hasChanges, isFalse);
      expect(diff.changedCount, 0);
      expect(diff.addedCount, 0);
      expect(diff.removedCount, 0);
    });

    test('a hop pointing at a new IP is a change', () {
      final diff = RouteDiff.between(
        [_hop(1, '10.0.0.1'), _hop(2, '10.0.0.2')],
        [_hop(1, '10.0.0.1'), _hop(2, '10.0.0.9')],
      );
      expect(diff.changedCount, 1);
      expect(diff.hasChanges, isTrue);
      final d = diff.deltas.firstWhere((d) => d.hopNum == 2);
      expect(d.kind, 'changed');
      expect(d.beforeIp, '10.0.0.2');
      expect(d.afterIp, '10.0.0.9');
    });

    test('a previously silent hop becoming visible is "added"', () {
      final diff = RouteDiff.between(
        [_hop(1, '10.0.0.1'), _hop(2, '*', timeout: true)],
        [_hop(1, '10.0.0.1'), _hop(2, '10.0.0.2')],
      );
      expect(diff.addedCount, 1);
      expect(diff.changedCount, 0);
      expect(diff.deltas.firstWhere((d) => d.hopNum == 2).kind, 'added');
    });

    test('a hop that stops answering is "removed", not "changed"', () {
      final diff = RouteDiff.between(
        [_hop(1, '10.0.0.1'), _hop(2, '10.0.0.2')],
        [_hop(1, '10.0.0.1'), _hop(2, '*', timeout: true)],
      );
      expect(diff.removedCount, 1);
      expect(diff.changedCount, 0);
      expect(diff.deltas.firstWhere((d) => d.hopNum == 2).kind, 'removed');
    });

    test('both-timeout hops are not a route change (rate limiting, not '
        'a path change)', () {
      final diff = RouteDiff.between(
        [_hop(1, '10.0.0.1'), _hop(2, '*', timeout: true)],
        [_hop(1, '10.0.0.1'), _hop(2, '*', timeout: true)],
      );
      expect(diff.hasChanges, isFalse);
      expect(diff.changedCount + diff.addedCount + diff.removedCount, 0);
    });

    test('a longer path adds the new tail hops', () {
      final diff = RouteDiff.between(
        [_hop(1, '10.0.0.1')],
        [_hop(1, '10.0.0.1'), _hop(2, '10.0.0.2'), _hop(3, '8.8.8.8')],
      );
      expect(diff.addedCount, 2);
      expect(diff.removedCount, 0);
    });

    test('a shorter path marks the vanished hops removed', () {
      final diff = RouteDiff.between(
        [_hop(1, '10.0.0.1'), _hop(2, '10.0.0.2'), _hop(3, '8.8.8.8')],
        [_hop(1, '10.0.0.1')],
      );
      expect(diff.removedCount, 2);
    });

    test('empty inputs never signal a change (first trace baseline)', () {
      expect(RouteDiff.between([], [_hop(1, '10.0.0.1')]).hasChanges, isFalse);
      expect(RouteDiff.between([_hop(1, '10.0.0.1')], []).hasChanges, isFalse);
      expect(RouteDiff.between([], []).hasChanges, isFalse);
    });

    test('deltas are sorted by hop number', () {
      final diff = RouteDiff.between(
        [_hop(3, '10.0.0.3'), _hop(1, '10.0.0.1')],
        [_hop(3, '10.0.0.30'), _hop(1, '10.0.0.10')],
      );
      expect(diff.deltas.map((d) => d.hopNum).toList(), [1, 3]);
    });
  });
}

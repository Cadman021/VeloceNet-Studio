import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/ping_target.dart';
import 'package:netstudio/models/traceroute_hop.dart';
import 'package:netstudio/views/mtr/mtr_controller.dart';

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
  group('MtrController.buildHopTargets', () {
    test('maps responding hops to ICMP targets with stable ids', () {
      final targets = MtrController.buildHopTargets([
        _hop(1, '192.168.1.1'),
        _hop(2, '*', timeout: true),
        _hop(3, '8.8.8.8'),
      ]);
      expect(targets, hasLength(2));
      expect(targets[0].id, mtrHopId(1));
      expect(targets[1].id, mtrHopId(3));
      expect(targets[0].protocol, NetworkProtocol.icmp);
      expect(targets[0].host, '192.168.1.1');
      // Far above matrix/warp id ranges: no collision possible.
      expect(targets[0].id, greaterThan(100000));
    });

    test('empty and all-timeout traces yield no targets', () {
      expect(MtrController.buildHopTargets([]), isEmpty);
      expect(
          MtrController.buildHopTargets([_hop(1, '*', timeout: true)]),
          isEmpty);
    });

    test('hop ids are stable across rebuilds', () {
      final a = MtrController.buildHopTargets([_hop(2, '1.2.3.4')]);
      final b = MtrController.buildHopTargets([_hop(2, '1.2.3.4')]);
      expect(a.single.id, b.single.id);
    });
  });
}

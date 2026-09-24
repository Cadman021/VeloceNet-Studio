import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/services/network_engine_service.dart';

const _sample = '''
[
  {
    "id": 1,
    "name": "Cloudflare",
    "host": "1.1.1.1",
    "port": 53,
    "protocol": "ICMP",
    "status": "Online",
    "sent_count": 10,
    "received_count": 9,
    "lost_count": 1,
    "loss_rate": 10.0,
    "last_rtt_ms": 22.5,
    "min_rtt_ms": 18.0,
    "max_rtt_ms": 40.0,
    "avg_rtt_ms": 24.0,
    "jitter_ms": 2.5,
    "history": [20.0, 22.5, -1.0],
    "last_checked_epoch_ms": 1726857600000
  }
]
''';

void main() {
  group('decodeMetricsSnapshot', () {
    test('decodes a valid native snapshot', () {
      final metrics = decodeMetricsSnapshot(_sample);
      expect(metrics, hasLength(1));
      final m = metrics.first;
      expect(m.id, 1);
      expect(m.name, 'Cloudflare');
      expect(m.sentCount, 10);
      expect(m.lostCount, 1);
      expect(m.history, [20.0, 22.5, -1.0]);
    });

    test('malformed payload yields empty list, never throws', () {
      expect(decodeMetricsSnapshot(''), isEmpty);
      expect(decodeMetricsSnapshot('not json'), isEmpty);
      expect(decodeMetricsSnapshot('{"id": 1}'), isEmpty);
      expect(decodeMetricsSnapshot('[42]'), isEmpty);
    });
  });
}

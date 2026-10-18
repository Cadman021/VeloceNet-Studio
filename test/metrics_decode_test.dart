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

const _httpSample = '''
[
  {
    "id": 7,
    "name": "Cloudflare HTTPS",
    "host": "cloudflare.com",
    "port": 443,
    "protocol": "HTTPS",
    "status": "Online",
    "sent_count": 4,
    "received_count": 4,
    "lost_count": 0,
    "loss_rate": 0.0,
    "last_rtt_ms": 88.2,
    "min_rtt_ms": 70.0,
    "max_rtt_ms": 95.0,
    "avg_rtt_ms": 85.0,
    "jitter_ms": 3.1,
    "history": [88.2],
    "last_checked_epoch_ms": 1726857600000,
    "http_status": 204,
    "cert_days_left": 47
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
      expect(m.httpStatus, isNull);
      expect(m.certDaysLeft, isNull);
    });

    test('decodes HTTP status and TLS cert days', () {
      final m = decodeMetricsSnapshot(_httpSample).single;
      expect(m.protocol, 'HTTPS');
      expect(m.httpStatus, 204);
      expect(m.certDaysLeft, 47);
    });

    test('malformed payload yields empty list, never throws', () {
      expect(decodeMetricsSnapshot(''), isEmpty);
      expect(decodeMetricsSnapshot('not json'), isEmpty);
      expect(decodeMetricsSnapshot('{"id": 1}'), isEmpty);
      expect(decodeMetricsSnapshot('[42]'), isEmpty);
    });
  });
}

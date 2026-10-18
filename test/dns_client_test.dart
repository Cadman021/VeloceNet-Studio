import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/services/dns_client.dart';

List<int> _ascii(String s) => s.codeUnits;

/// Builds a minimal response for `example.com` with one answer.
/// Layout: header, question (pointer target), answer with compressed name.
List<int> _response({
  required int txid,
  required int flags,
  required List<int> answer,
}) {
  return [
    txid >> 8, txid & 0xFF,
    flags >> 8, flags & 0xFF,
    0x00, 0x01, // QDCOUNT
    0x00, 0x01, // ANCOUNT
    0x00, 0x00, 0x00, 0x00, // NSCOUNT, ARCOUNT
    0x07, ..._ascii('example'), 0x03, ..._ascii('com'), 0x00,
    0x00, 0x01, 0x00, 0x01, // QTYPE=A, QCLASS=IN
    ...answer,
  ];
}

void main() {
  group('buildDnsQuery', () {
    test('structure: RD flag, one question, IN class, EDNS OPT', () {
      final built = buildDnsQuery('example.com', 1);
      final packet = built.$1;
      expect(packet[2], 0x01);
      expect(packet[3], 0x00);
      expect(packet[4], 0x00);
      expect(packet[5], 0x01);
      expect(packet[10], 0x00);
      expect(packet[11], 0x01); // ARCOUNT = 1 (OPT)
      // QTYPE/QCLASS then the 11-byte OPT record (type 41, size 4096).
      final qEnd = packet.length - 15;
      expect(packet.sublist(qEnd, qEnd + 4), [0x00, 0x01, 0x00, 0x01]);
      expect(packet.sublist(packet.length - 11),
          [0x00, 0x00, 0x29, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    });

    test('IDN and trailing-dot queries encode correctly', () {
      final idn = buildDnsQuery('münchen.de', 1).$1;
      // xn--mnchen-3ya label; no raw UTF-8 bytes anywhere past the
      // 2 random txid bytes (which legitimately span 0..255).
      expect(idn.sublist(2).any((b) => b > 127), isFalse);
      final dotted = buildDnsQuery('example.com.', 1).$1;
      final plain = buildDnsQuery('example.com', 1).$1;
      // Same length prefix apart from txid: strip first 2 bytes to compare.
      expect(dotted.sublist(2), plain.sublist(2));
    });

    test('txids vary (secure random)', () {
      final ids = {
        for (int i = 0; i < 16; i++) buildDnsQuery('example.com', 1).$2
      };
      expect(ids.length, greaterThan(1));
    });

    test('rejects bad names', () {
      expect(() => buildDnsQuery('', 1), throwsA(isA<DnsException>()));
      expect(() => buildDnsQuery('a' * 64 + '.com', 1),
          throwsA(isA<DnsException>()));
    });
  });

  group('decodeDnsResponse', () {
    test('A record with compressed name', () {
      const txid = 0x1234;
      final packet = _response(
        txid: txid,
        flags: 0x8180,
        answer: [
          0xC0, 0x0C, // NAME -> offset 12 (the question)
          0x00, 0x01, 0x00, 0x01, // TYPE=A, CLASS=IN
          0x00, 0x00, 0x01, 0x2C, // TTL=300
          0x00, 0x04, 93, 184, 216, 34,
        ],
      );
      final records = decodeDnsResponse(packet, txid);
      expect(records, hasLength(1));
      expect(records.first.name, 'example.com');
      expect(records.first.type, 'A');
      expect(records.first.ttl, 300);
      expect(records.first.data, '93.184.216.34');
    });

    test('AAAA record with zero compression', () {
      const txid = 0xABCD;
      final packet = _response(
        txid: txid,
        flags: 0x8180,
        answer: [
          0xC0, 0x0C,
          0x00, 0x1C, 0x00, 0x01, // TYPE=AAAA
          0x00, 0x00, 0x00, 0x3C, // TTL=60
          0x00, 0x10,
          0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01,
          0x02, 0x48, 0x18, 0x93, 0x25, 0xC8, 0x19, 0x46,
        ],
      );
      final records = decodeDnsResponse(packet, txid);
      expect(records.first.data, '2606:2800:220:1:248:1893:25c8:1946');
    });

    test('TXT record', () {
      const txid = 0x0001;
      final txt = _ascii('v=spf1 include:_spf.google.com ~all');
      final packet = _response(
        txid: txid,
        flags: 0x8180,
        answer: [
          0xC0, 0x0C,
          0x00, 0x10, 0x00, 0x01, // TYPE=TXT
          0x00, 0x00, 0x00, 0x3C,
          0x00, txt.length + 1, txt.length, ...txt,
        ],
      );
      final records = decodeDnsResponse(packet, txid);
      expect(records.first.data, 'v=spf1 include:_spf.google.com ~all');
    });

    test('NXDOMAIN surfaces distinctly', () {
      const txid = 0x1234;
      final packet = _response(txid: txid, flags: 0x8183, answer: const []);
      expect(
        () => decodeDnsResponse(packet, txid),
        throwsA(isA<DnsNxDomain>()),
      );
    });

    test('transaction id mismatch rejected', () {
      const txid = 0x1234;
      final packet = _response(
        txid: 0x9999,
        flags: 0x8180,
        answer: const [],
      );
      expect(
        () => decodeDnsResponse(packet, txid),
        throwsA(
          isA<DnsException>().having(
            (e) => e.message,
            'message',
            'Transaction id mismatch',
          ),
        ),
      );
    });

    test('truncated packet rejected, never crashes', () {
      expect(
        () => decodeDnsResponse([0x12, 0x34, 0x81], 0x1234),
        throwsA(isA<DnsException>()),
      );
    });
  });
}

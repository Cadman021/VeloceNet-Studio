import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Record types supported by the lookup tool.
enum DnsQueryType {
  a(1, 'A'),
  aaaa(28, 'AAAA'),
  cname(5, 'CNAME'),
  mx(15, 'MX'),
  ns(2, 'NS'),
  txt(16, 'TXT'),
  soa(6, 'SOA');

  final int code;
  final String label;
  const DnsQueryType(this.code, this.label);
}

/// One decoded resource record for display.
class DnsRecord {
  final String name;
  final String type;
  final int ttl;
  final String data;

  const DnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    required this.data,
  });
}

/// Decoded lookup result.
class DnsResponse {
  final String server;
  final List<DnsRecord> answers;
  final int queryTimeMs;
  final bool truncated;

  const DnsResponse({
    required this.server,
    required this.answers,
    required this.queryTimeMs,
    required this.truncated,
  });
}

class DnsException implements Exception {
  final String message;
  const DnsException(this.message);
  @override
  String toString() => 'DnsException: $message';
}

/// NXDOMAIN (RCODE 3): the name genuinely does not exist. Surfaced
/// separately so the UI can say so instead of a generic "failed".
class DnsNxDomain extends DnsException {
  const DnsNxDomain(super.message);
}

// ---------------------------------------------------------------------------
// Wire codec (pure functions — unit tested, no I/O).
// ---------------------------------------------------------------------------

/// Builds a standard recursive query packet. Returns (packet, txid).
(List<int>, int) buildDnsQuery(String name, int qtype) {
  final txid = Random().nextInt(0x10000);
  final out = <int>[
    txid >> 8,
    txid & 0xFF,
    0x01,
    0x00, // flags: RD
    0x00,
    0x01, // QDCOUNT = 1
    0x00,
    0x00, // ANCOUNT
    0x00,
    0x00, // NSCOUNT
    0x00,
    0x00, // ARCOUNT
  ];
  for (final label in name.split('.')) {
    final units = label.codeUnits;
    if (label.isEmpty || units.length > 63) {
      throw const DnsException('Invalid domain label');
    }
    out.add(units.length);
    out.addAll(units);
  }
  out.add(0); // root
  out.addAll([qtype >> 8, qtype & 0xFF, 0x00, 0x01]); // QTYPE, QCLASS=IN
  return (out, txid);
}

class _Reader {
  final List<int> bytes;
  int offset = 0;
  _Reader(this.bytes);

  int u16() {
    if (offset + 2 > bytes.length) throw const DnsException('Truncated');
    final v = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    return v;
  }

  int u32() {
    if (offset + 4 > bytes.length) throw const DnsException('Truncated');
    final v = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;
    return v;
  }

  /// Reads a (possibly compressed) domain name per RFC 1035 §4.1.4.
  String name() {
    final labels = <String>[];
    int pos = offset;
    int end = -1; // where `offset` resumes after pointer jumps
    int guard = 0;
    while (true) {
      if (++guard > 128) throw const DnsException('Bad compression');
      if (pos >= bytes.length) throw const DnsException('Truncated name');
      final len = bytes[pos];
      if (len == 0) {
        pos++;
        break;
      }
      if ((len & 0xC0) == 0xC0) {
        if (pos + 1 >= bytes.length) {
          throw const DnsException('Truncated pointer');
        }
        if (end == -1) end = pos + 2;
        pos = ((len & 0x3F) << 8) | bytes[pos + 1];
        continue;
      }
      if ((len & 0xC0) != 0 || pos + 1 + len > bytes.length) {
        throw const DnsException('Bad label');
      }
      labels.add(String.fromCharCodes(bytes.sublist(pos + 1, pos + 1 + len)));
      pos += 1 + len;
    }
    offset = end == -1 ? pos : end;
    return labels.join('.');
  }
}

String _formatIpv6(List<int> b) {
  final groups = <int>[];
  for (int i = 0; i < 16; i += 2) {
    groups.add((b[i] << 8) | b[i + 1]);
  }
  // Compress the longest zero run.
  int bestStart = -1, bestLen = 0, curStart = -1, curLen = 0;
  for (int i = 0; i <= 8; i++) {
    if (i < 8 && groups[i] == 0) {
      curStart = curStart == -1 ? i : curStart;
      curLen++;
    } else {
      if (curLen > bestLen) {
        bestLen = curLen;
        bestStart = curStart;
      }
      curStart = -1;
      curLen = 0;
    }
  }
  if (bestLen < 2) {
    return groups.map((g) => g.toRadixString(16)).join(':');
  }
  final head =
      groups.sublist(0, bestStart).map((g) => g.toRadixString(16)).join(':');
  final tail = groups
      .sublist(bestStart + bestLen)
      .map((g) => g.toRadixString(16))
      .join(':');
  if (head.isEmpty) return '::$tail';
  if (tail.isEmpty) return '$head::';
  return '$head::$tail';
}

/// Parses RDATA of a known type into display text. Unknown types hex-dump.
String _parseRdata(_Reader r, int type, int rdlen) {
  final start = r.offset;
  String readNameAtCurrent() => r.name();
  switch (type) {
    case 1: // A
      if (rdlen != 4) throw const DnsException('Bad A record');
      final b = r.bytes.sublist(r.offset, r.offset + 4);
      r.offset += 4;
      return b.join('.');
    case 28: // AAAA
      if (rdlen != 16) throw const DnsException('Bad AAAA record');
      final b = r.bytes.sublist(r.offset, r.offset + 16);
      r.offset += 16;
      return _formatIpv6(b);
    case 5: // CNAME
    case 2: // NS
      final target = readNameAtCurrent();
      r.offset = start + rdlen; // skip any trailing bytes
      return target;
    case 15: // MX
      final pref = r.u16();
      final exchange = readNameAtCurrent();
      r.offset = start + rdlen;
      return '$pref $exchange';
    case 16: // TXT (one or more <len> strings)
      final parts = <String>[];
      final end = start + rdlen;
      while (r.offset < end) {
        final len = r.bytes[r.offset++];
        if (r.offset + len > end) throw const DnsException('Bad TXT record');
        parts.add(String.fromCharCodes(r.bytes.sublist(r.offset, r.offset + len)));
        r.offset += len;
      }
      return parts.join(' ');
    case 6: // SOA
      final mname = readNameAtCurrent();
      final rname = readNameAtCurrent();
      final serial = r.u32();
      final refresh = r.u32();
      final retry = r.u32();
      final expire = r.u32();
      final minimum = r.u32();
      return '$mname $rname $serial $refresh $retry $expire $minimum';
    default:
      final b = r.bytes.sublist(start, start + rdlen);
      r.offset = start + rdlen;
      return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }
}

String _typeLabel(int type) {
  for (final t in DnsQueryType.values) {
    if (t.code == type) return t.label;
  }
  return 'TYPE$type';
}

/// Decodes a full response packet; verifies the transaction id.
List<DnsRecord> decodeDnsResponse(List<int> packet, int txid,
    {void Function(bool truncated)? onFlags}) {
  final r = _Reader(packet);
  final gotTxid = r.u16();
  if (gotTxid != txid) throw const DnsException('Transaction id mismatch');
  final flags = r.u16();
  if ((flags & 0x8000) == 0) throw const DnsException('Not a response');
  final rcode = flags & 0x000F;
  if (rcode == 3) throw const DnsNxDomain('Name does not exist (NXDOMAIN)');
  if (rcode != 0) throw DnsException('Server error (RCODE $rcode)');
  onFlags?.call((flags & 0x0200) != 0); // TC
  final qd = r.u16();
  final an = r.u16();
  r.u16(); // NSCOUNT (skipped for display)
  r.u16(); // ARCOUNT (skipped for display)
  for (int i = 0; i < qd; i++) {
    r.name();
    r.u16(); // QTYPE
    r.u16(); // QCLASS
  }
  final out = <DnsRecord>[];
  for (int i = 0; i < an; i++) {
    final name = r.name();
    final type = r.u16();
    r.u16(); // CLASS
    final ttl = r.u32();
    final rdlen = r.u16();
    if (r.offset + rdlen > r.bytes.length) {
      throw const DnsException('Truncated RDATA');
    }
    final data = _parseRdata(r, type, rdlen);
    out.add(DnsRecord(name: name, type: _typeLabel(type), ttl: ttl, data: data));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Transport.
// ---------------------------------------------------------------------------

/// Sends a raw DNS query over UDP and decodes the response.
///
/// [serverIp] must be an IP literal (validated by the caller). Throws
/// [DnsException]/[DnsNxDomain] on protocol errors and [TimeoutException]
/// when the server stays silent past [timeoutMs].
Future<DnsResponse> lookupDns({
  required String name,
  required DnsQueryType qtype,
  required String serverIp,
  int port = 53,
  int timeoutMs = 2000,
}) async {
  final server = InternetAddress.tryParse(serverIp);
  if (server == null) throw const DnsException('Invalid DNS server IP');
  final built = buildDnsQuery(name, qtype.code);
  final packet = built.$1;
  final txid = built.$2;

  // Family-matched bind: an IPv4-bound socket can never receive an IPv6
  // server's reply (and vice versa without dual-stack), which made every
  // custom IPv6 server silently time out.
  final bindAddr = server.type == InternetAddressType.IPv6
      ? InternetAddress.anyIPv6
      : InternetAddress.anyIPv4;
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(bindAddr, 0)
        .timeout(Duration(milliseconds: timeoutMs));
  } on TimeoutException {
    throw const DnsException('Socket bind timed out');
  }
  final socket = sock;
  final stopwatch = Stopwatch()..start();
  socket.send(packet, server, port);
  // Single subscription (RawDatagramSocket is single-subscription):
  // buffer every readable datagram, answer the first one carrying our
  // transaction id, and fail on a hard deadline.
  final completer = Completer<DnsResponse>.sync();
  late StreamSubscription<RawSocketEvent> sub;
  final timer = Timer(Duration(milliseconds: timeoutMs), () {
    if (!completer.isCompleted) {
      completer.completeError(
        TimeoutException('DNS query to $serverIp timed out'),
      );
    }
  });
  sub = socket.listen(
    (event) async {
      if (event != RawSocketEvent.read || completer.isCompleted) return;
      Datagram? dg;
      while ((dg = socket.receive()) != null && !completer.isCompleted) {
        // Source check: only the queried server may answer (spoofed or
        // stray packets are ignored instead of decoded).
        if (dg!.address.address != server.address) continue;
        final data = dg.data;
        bool truncated = false;
        try {
          final answers = decodeDnsResponse(data, txid,
              onFlags: (tc) => truncated = tc);
          stopwatch.stop();
          if (truncated) {
            // UDP answer didn't fit: retry the same query over TCP
            // (RFC 1035 §4.2.2). If TCP also fails, fall back to the
            // partial UDP answers with the flag set.
            try {
              final tcp = await _lookupDnsTcp(
                name: name,
                qtype: qtype,
                serverIp: serverIp,
                port: port,
                timeoutMs: timeoutMs,
              );
              completer.complete(tcp);
            } catch (_) {
              completer.complete(DnsResponse(
                server: serverIp,
                answers: answers,
                queryTimeMs:
                    (stopwatch.elapsedMicroseconds / 1000).round(),
                truncated: true,
              ));
            }
          } else {
            completer.complete(DnsResponse(
              server: serverIp,
              answers: answers,
              queryTimeMs: (stopwatch.elapsedMicroseconds / 1000).round(),
              truncated: false,
            ));
          }
          return;
        } on DnsException catch (e) {
          // Someone else's packet: keep waiting for ours.
          if (e.message != 'Transaction id mismatch') {
            completer.completeError(e);
            return;
          }
        }
      }
    },
    onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
    cancelOnError: false,
  );
  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
    socket.close();
    stopwatch.stop();
  }
}

/// Same query over TCP (RFC 1035 §4.2.2 framing: 2-byte length prefix).
/// Used as fallback when a UDP reply arrives with the TC flag.
Future<DnsResponse> _lookupDnsTcp({
  required String name,
  required DnsQueryType qtype,
  required String serverIp,
  required int port,
  required int timeoutMs,
}) async {
  final built = buildDnsQuery(name, qtype.code);
  final packet = built.$1;
  final txid = built.$2;
  final server = InternetAddress(serverIp);
  final stopwatch = Stopwatch()..start();

  Socket? sock;
  try {
    sock = await Socket.connect(
      server,
      port,
      timeout: Duration(milliseconds: timeoutMs),
    );
  } catch (_) {
    throw const DnsException('TCP fallback connect failed');
  }
  final socket = sock;
  final completer = Completer<List<int>>.sync();
  final buf = <int>[];
  int? need;
  late StreamSubscription<List<int>> sub;
  final timer = Timer(Duration(milliseconds: timeoutMs), () {
    if (!completer.isCompleted) {
      completer.completeError(
        TimeoutException('DNS/TCP read from $serverIp timed out'),
      );
    }
  });
  sub = socket.listen(
    (chunk) {
      if (completer.isCompleted) return;
      buf.addAll(chunk);
      if (need == null && buf.length >= 2) {
        need = ((buf[0] << 8) | buf[1]) + 2;
      }
      if (need != null && buf.length >= need!) {
        completer.complete(buf.sublist(2, need));
      }
    },
    onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer.completeError(const DnsException('TCP closed early'));
      }
    },
    cancelOnError: false,
  );
  try {
    socket.add([packet.length >> 8, packet.length & 0xFF, ...packet]);
    final body = await completer.future;
    stopwatch.stop();
    final answers = decodeDnsResponse(body, txid);
    return DnsResponse(
      server: serverIp,
      answers: answers,
      queryTimeMs: (stopwatch.elapsedMicroseconds / 1000).round(),
      truncated: false,
    );
  } finally {
    timer.cancel();
    await sub.cancel();
    socket.destroy();
    stopwatch.stop();
  }
}

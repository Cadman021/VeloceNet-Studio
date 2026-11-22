import 'dart:convert';
import 'dart:typed_data';

import '../core/validation/host_validator.dart';

/// Cloudflare's published consumer-WARP peer public key (base64).
/// Kept in sync with `DEFAULT_WARP_PEER_KEY` in `native_engine/src/wireguard.rs`.
const String kWarpDefaultPeerKey =
    'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';

/// A parsed WireGuard profile (`.conf`, including `wgcf` output).
///
/// Only the pieces a handshake probe needs are kept: the private key of the
/// local identity, the peer's public key and the peer endpoint. Address/DNS/
/// AllowedIPs are parsed for display but never used to route host traffic —
/// VeloceNet only sends a single handshake initiation from an ephemeral UDP
/// socket, so the profile is NOT installed as a tunnel.
///
/// Security: the private key stays in memory for this session only. It is
/// deliberately absent from [toMap]/[toString] and never persisted by the
/// app; users must re-import the profile after a restart.
class WarpProfile {
  /// Canonical (standard base64) private key. Do not display or log.
  final String privateKey;

  /// Canonical base64 peer public key (safe to display).
  final String publicKey;

  final Uint8List privateKeyBytes;
  final Uint8List publicKeyBytes;

  final String endpointHost;
  final int endpointPort;

  /// `Address` entries from the [Interface] section (CIDR strings), shown
  /// for identification only.
  final List<String> addresses;

  const WarpProfile({
    required this.privateKey,
    required this.publicKey,
    required this.privateKeyBytes,
    required this.publicKeyBytes,
    required this.endpointHost,
    required this.endpointPort,
    required this.addresses,
  });

  bool get isCloudflareWarp => publicKey == kWarpDefaultPeerKey;

  /// `host:port`, bracketed for IPv6 literals.
  String get displayEndpoint => endpointHost.contains(':')
      ? '[$endpointHost]:$endpointPort'
      : '$endpointHost:$endpointPort';

  /// Short identity hint for the UI — never includes the private key.
  String get identityHint {
    final prefix =
        publicKey.length <= 12 ? publicKey : '${publicKey.substring(0, 12)}…';
    return prefix;
  }

  /// Parses a WireGuard configuration. Returns a result object instead of
  /// throwing so the UI can show the exact reason an import was rejected.
  static WarpProfileParseResult parse(String raw) {
    var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    final sections = <String, Map<String, String>>{};
    var section = '';
    for (final rawLine in text.split('\n')) {
      var line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).trim().toLowerCase();
        sections.putIfAbsent(section, () => {});
        continue;
      }
      final eq = line.indexOf('=');
      if (eq <= 0 || section.isEmpty) continue;
      final key = line.substring(0, eq).trim().toLowerCase();
      var value = line.substring(eq + 1).trim();
      // Strip a trailing inline comment only when it is whitespace-prefixed;
      // base64 keys use +=/ and hostnames cannot contain '#'.
      final comment = RegExp(r'\s[#;].*$').firstMatch(value);
      if (comment != null) {
        value = value.substring(0, comment.start).trim();
      }
      if (value.isEmpty) continue;
      sections[section]![key] = value;
    }

    final iface = sections['interface'];
    if (iface == null) {
      return const WarpProfileParseResult.failure(
          'Missing [Interface] section.');
    }
    final peer = sections['peer'];
    if (peer == null) {
      return const WarpProfileParseResult.failure('Missing [Peer] section.');
    }

    final privateBytes = _decodeKey(iface['privatekey']);
    if (privateBytes == null) {
      return const WarpProfileParseResult.failure(
          'PrivateKey is missing or is not a 32-byte base64 key.');
    }
    final publicBytes = _decodeKey(peer['publickey']);
    if (publicBytes == null) {
      return const WarpProfileParseResult.failure(
          'PublicKey is missing or is not a 32-byte base64 key.');
    }

    final endpointRaw = peer['endpoint'];
    if (endpointRaw == null || endpointRaw.trim().isEmpty) {
      return const WarpProfileParseResult.failure(
          'Endpoint is missing (expected host:port).');
    }
    final endpoint = _parseEndpoint(endpointRaw);
    if (endpoint == null) {
      return const WarpProfileParseResult.failure(
          'Endpoint is malformed (expected host:port, IPv6 as [addr]:port).');
    }

    final addresses = <String>[];
    for (final a in (iface['address'] ?? '').split(',')) {
      final value = a.trim();
      if (value.isNotEmpty) addresses.add(value);
    }

    return WarpProfileParseResult.success(WarpProfile(
      privateKey: base64.encode(privateBytes),
      publicKey: base64.encode(publicBytes),
      privateKeyBytes: Uint8List.fromList(privateBytes),
      publicKeyBytes: Uint8List.fromList(publicBytes),
      endpointHost: endpoint.host,
      endpointPort: endpoint.port,
      addresses: List.unmodifiable(addresses),
    ));
  }

  static Uint8List? _decodeKey(String? value) {
    if (value == null) return null;
    var s = value.trim();
    if (s.isEmpty) return null;
    // Accept url-safe variants defensively, then normalize padding.
    s = s.replaceAll('-', '+').replaceAll('_', '/');
    if (s.length % 4 != 0) s = s.padRight((s.length + 3) ~/ 4 * 4, '=');
    try {
      final bytes = base64.decode(s);
      return bytes.length == 32 ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  static ({String host, int port})? _parseEndpoint(String raw) {
    final s = raw.trim();
    String? host;
    String? portStr;

    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end < 0) return null;
      host = s.substring(1, end);
      final rest = s.substring(end + 1);
      if (rest.startsWith(':')) {
        portStr = rest.substring(1);
      } else if (rest.isNotEmpty) {
        return null;
      }
    } else {
      final lastColon = s.lastIndexOf(':');
      if (lastColon > 0 && s.indexOf(':') == lastColon) {
        host = s.substring(0, lastColon);
        portStr = s.substring(lastColon + 1);
      } else if (lastColon > 0) {
        // Bare IPv6 without brackets is ambiguous; require [addr]:port.
        return null;
      } else {
        host = s;
      }
    }

    final normalizedHost = normalizeTraceHost(host);
    if (normalizedHost == null) return null;
    // A hostname resolving is checked at validation time; parsing only
    // proves the shape is a legal host.
    var port = 51820;
    if (portStr != null && portStr.trim().isNotEmpty) {
      final parsed = int.tryParse(portStr.trim());
      if (parsed == null || parsed < 1 || parsed > 65535) return null;
      port = parsed;
    }
    return (host: normalizedHost, port: port);
  }

  /// Public metadata only — intentionally excludes the private key.
  Map<String, dynamic> toMap() => {
        'endpoint': displayEndpoint,
        'publicKey': publicKey,
        'addresses': addresses,
        'isCloudflareWarp': isCloudflareWarp,
      };

  @override
  String toString() =>
      'WarpProfile($displayEndpoint, peer $identityHint, private key hidden)';
}

/// Outcome of probing a profile's endpoint with the profile identity.
///
/// `confirmed` is the only state that proves the server accepted the
/// imported identity (a validated WireGuard handshake response). A TCP
/// fallback only proves the host is reachable.
enum WarpProfileValidationStatus {
  confirmed,
  reachableOnly,
  failed,
  unsupported,
}

class WarpProfileValidation {
  final WarpProfileValidationStatus status;
  final String endpoint;
  final double rttMs;
  final String detail;

  const WarpProfileValidation({
    required this.status,
    required this.endpoint,
    this.rttMs = -1,
    this.detail = '',
  });

  bool get isConfirmed => status == WarpProfileValidationStatus.confirmed;
}

/// Success/failure wrapper for [WarpProfile.parse].
class WarpProfileParseResult {
  final WarpProfile? profile;
  final String? error;

  const WarpProfileParseResult._(this.profile, this.error);

  const WarpProfileParseResult.success(WarpProfile value) : this._(value, null);

  const WarpProfileParseResult.failure(String message) : this._(null, message);

  bool get ok => profile != null;
}

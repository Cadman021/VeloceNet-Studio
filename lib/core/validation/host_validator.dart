import 'dart:io';

/// Shared host validation/normalization for every feature that probes a
/// user-supplied target (traceroute, port scanner, DNS lookup, add-server
/// dialog, config import). Single source of truth — do not duplicate.
///
/// Validates IPv4 (octet-checked), IPv6 (with or without brackets) and DNS
/// hostnames. Returns the normalized host, or null when invalid.
String? normalizeTraceHost(String raw) {
  var host =
      raw.trim().replaceAll(RegExp(r'^https?://'), '').split('/')[0].trim();
  // A trailing root dot is a valid FQDN form ("example.com.") that breaks
  // naive length/label checks and downstream encoders alike.
  if (host.endsWith('.') && host.length > 1) {
    host = host.substring(0, host.length - 1);
  }
  if (host.startsWith('[') && host.endsWith(']') && host.length > 2) {
    host = host.substring(1, host.length - 1);
  }
  if (host.isEmpty || host.length > 253) return null;
  // IPv4 (octet-checked, not just dotted digits).
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
    final ok = host.split('.').every((o) {
      final n = int.tryParse(o);
      return n != null && n >= 0 && n <= 255;
    });
    return ok ? host : null;
  }
  // IPv6 literal.
  if (host.contains(':')) {
    final addr = InternetAddress.tryParse(host);
    return (addr != null && addr.type == InternetAddressType.IPv6)
        ? host
        : null;
  }
  // Hostname (labels up to 63 chars, no leading/trailing hyphens).
  const label = r'[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?';
  if (RegExp('^$label(?:\\.$label)*\$').hasMatch(host)) return host;
  return null;
}

/// Validates a Discord webhook URL: https scheme plus a discord-owned host
/// (`discord.com/api/webhooks/...`, incl. ptb./canary. subdomains).
bool isValidDiscordWebhookUrl(String raw) {
  Uri? uri;
  try {
    uri = Uri.parse(raw.trim());
  } catch (_) {
    return false;
  }
  if (!uri.isAbsolute || uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  return host == 'discord.com' ||
      host == 'discordapp.com' ||
      host.endsWith('.discord.com') ||
      host.endsWith('.discordapp.com');
}

/// Validates a generic outbound webhook URL: absolute http(s) with a host.
/// Deliberately NOT scheme-locked to https — self-hosted receivers (ntfy,
/// Gotify, an internal bridge) commonly run on plain http on a LAN, and the
/// URL is entered by the operator, not attacker-controlled.
bool isValidGenericWebhookUrl(String raw) {
  Uri? uri;
  try {
    uri = Uri.parse(raw.trim());
  } catch (_) {
    return false;
  }
  if (!uri.isAbsolute) return false;
  if (uri.scheme != 'https' && uri.scheme != 'http') return false;
  return uri.host.isNotEmpty;
}

/// Validates an ntfy topic name (the path component appended to the ntfy
/// server URL). ntfy allows `[-_A-Za-z0-9]`, 1–64 chars; a leading `/` from
/// a pasted URL is tolerated and stripped by the caller.
bool isValidNtfyTopic(String raw) {
  final topic = raw.trim();
  if (topic.isEmpty || topic.length > 64) return false;
  return RegExp(r'^[-_A-Za-z0-9]+$').hasMatch(topic);
}

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Update discovery via the GitHub Releases API. No new dependencies
/// (package:http was already in use for webhooks).
const String kReleasesLatestApi =
    'https://api.github.com/repos/Cadman021/VeloceNet-Studio/releases/latest';
const String kReleasesPageUrl =
    'https://github.com/Cadman021/VeloceNet-Studio/releases';

class UpdateInfo {
  /// Version without a leading `v` (e.g. `1.4.0`).
  final String version;
  final String url;
  final String notes;

  const UpdateInfo({
    required this.version,
    required this.url,
    required this.notes,
  });
}

/// Tolerant semver comparison: strips a leading `v`, compares leading
/// numeric runs per dot-separated part, treats missing parts as 0.
/// Returns -1 / 0 / 1. Pure function — unit tested.
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    return s.split('.').map((p) {
      final m = RegExp(r'^\d+').firstMatch(p.trim());
      return m == null ? 0 : int.parse(m.group(0)!);
    }).toList();
  }

  final pa = parts(a);
  final pb = parts(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (int i = 0; i < len; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Fetches the latest GitHub release. Returns null on any failure
/// (offline, rate-limited, malformed) — callers treat that as "unknown",
/// never as an error to surface loudly.
Future<UpdateInfo?> fetchLatestRelease({
  http.Client? client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final c = client ?? http.Client();
  try {
    final resp = await c
        .get(
          Uri.parse(kReleasesLatestApi),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(timeout);
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) return null;
    var tag = (decoded['tag_name'] ?? '').toString().trim();
    if (tag.startsWith('v') || tag.startsWith('V')) {
      tag = tag.substring(1);
    }
    if (tag.isEmpty) return null;
    return UpdateInfo(
      version: tag,
      url: (decoded['html_url'] ?? kReleasesPageUrl).toString(),
      notes: (decoded['body'] ?? '').toString(),
    );
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

/// Daily throttle gate (pure, unit tested): auto-check at most once a day;
/// manual "check now" taps always pass `force: true`.
bool shouldAutoCheck(DateTime? lastCheck, DateTime now) {
  if (lastCheck == null) return true;
  return now.difference(lastCheck) >= const Duration(hours: 24);
}

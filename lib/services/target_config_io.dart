import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../core/validation/host_validator.dart';
import '../models/ping_target.dart';

/// Backup envelope version. Bump when the schema changes.
const int kTargetBackupVersion = 1;
const int kMaxImportTargets = 500;

/// Result of parsing an imported backup.
class TargetImportResult {
  /// Drafts with `id` unset (0) — the caller reassigns collision-free ids.
  final List<PingTarget> targets;
  final int skipped;

  const TargetImportResult({required this.targets, required this.skipped});
}

/// Serializes targets into a versioned backup envelope. Pure, unit tested.
String exportTargetsJson(List<PingTarget> targets) {
  final envelope = {
    'app': 'velocenet-studio',
    'version': kTargetBackupVersion,
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    'targets': targets.map((t) => t.toJson()).toList(),
  };
  return const JsonEncoder.withIndent('  ').convert(envelope);
}

/// Parses a backup produced by [exportTargetsJson] (or hand-written in the
/// same shape). Hardened: never throws, validates every field, ignores
/// stored ids (reassigned on import), caps the entry count.
TargetImportResult importTargetsJson(String raw) {
  List<dynamic> entries;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      entries = decoded; // tolerate a bare array too
    } else if (decoded is Map<String, dynamic>) {
      final list = decoded['targets'];
      if (list is! List) {
        return const TargetImportResult(targets: [], skipped: 0);
      }
      entries = list;
    } else {
      return const TargetImportResult(targets: [], skipped: 0);
    }
  } catch (_) {
    return const TargetImportResult(targets: [], skipped: 0);
  }

  final targets = <PingTarget>[];
  int skipped = 0;
  for (final entry in entries) {
    if (targets.length >= kMaxImportTargets) {
      skipped++;
      continue;
    }
    final draft = _parseTarget(entry);
    if (draft == null) {
      skipped++;
    } else {
      targets.add(draft);
    }
  }
  return TargetImportResult(targets: targets, skipped: skipped);
}

/// Decodes our own persisted target list (same envelope as
/// [exportTargetsJson]). Unlike imports, ids are KEPT (validated positive)
/// so metrics/history continuity survives restarts; duplicate ids are
/// dropped. Returns null when there is nothing usable (caller falls back
/// to defaults). Never throws.
List<PingTarget>? decodePersistedTargets(String raw) {
  List<dynamic> entries;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      entries = decoded;
    } else if (decoded is Map<String, dynamic>) {
      final list = decoded['targets'];
      if (list is! List) return null;
      entries = list;
    } else {
      return null;
    }
  } catch (_) {
    return null;
  }

  final targets = <PingTarget>[];
  final seenIds = <int>{};
  for (final entry in entries) {
    if (targets.length >= kMaxImportTargets) break;
    final t = _parseTarget(entry, keepId: true);
    if (t == null || !seenIds.add(t.id)) continue;
    targets.add(t);
  }
  return targets.isEmpty ? null : targets;
}

PingTarget? _parseTarget(dynamic entry, {bool keepId = false}) {
  if (entry is! Map) return null;
  final map = Map<String, dynamic>.from(entry);

  // Persistence round-trip keeps ids (continuity for metrics/history);
  // backups ignore them (collision-free reassignment on import).
  int id = 0;
  if (keepId) {
    final rawId = map['id'];
    final parsed = rawId is num ? rawId.toInt() : int.tryParse('$rawId');
    if (parsed == null || parsed <= 0) return null;
    id = parsed;
  }

  final rawHost = (map['host'] ?? '').toString();
  final host = normalizeTraceHost(rawHost);
  if (host == null) return null;

  // Absent port defaults to 80 (like PingTarget); a present but
  // malformed/out-of-range port rejects the entry.
  final rawPort = map['port'];
  int port = 80;
  if (rawPort != null) {
    final parsed = rawPort is num ? rawPort.toInt() : int.tryParse('$rawPort');
    if (parsed == null || parsed < 1 || parsed > 65535) return null;
    port = parsed;
  }

  final protocol = _parseProtocol(map['protocol']);
  final httpPath = protocol.isHttp
      ? PingTarget.sanitizeHttpPath(map['http_path']?.toString())
      : '';

  int intOr(dynamic v, int fallback, int min, int max) {
    final n = v is num ? v.toInt() : int.tryParse('$v');
    if (n == null) return fallback;
    return n.clamp(min, max);
  }

  var name = (map['name'] ?? '').toString().trim();
  if (name.isEmpty) name = host;
  if (name.length > 128) name = name.substring(0, 128);

  final enabled = map['is_enabled'];
  final muted = map['is_muted'] ?? map['muted'];
  // Tolerant: `tags` may be a list or a comma-separated string (hand-written
  // backups); a legacy singular `tag` is accepted too.
  final rawTags = map['tags'] ?? (map['tag'] != null ? [map['tag']] : null);
  return PingTarget(
    id: id, // 0 unless keepId (controller reassigns those)
    name: name,
    host: host,
    port: port,
    protocol: protocol,
    httpPath: httpPath,
    intervalMs: intOr(map['interval_ms'], 1000, 200, 60000),
    timeoutMs: intOr(map['timeout_ms'], 1500, 100, 10000),
    isEnabled: enabled is bool ? enabled : true,
    muted: muted is bool ? muted : false,
    group: PingTarget.sanitizeGroup(map['group']?.toString()),
    tags: PingTarget.parseTags(rawTags),
  );
}

NetworkProtocol _parseProtocol(dynamic v) {
  if (v is num) {
    return NetworkProtocol.fromId(v.toInt());
  }
  final s = '$v'.trim().toUpperCase();
  if (s == 'TCP' || s == '1') return NetworkProtocol.tcp;
  if (s == 'HTTP' || s == '2') return NetworkProtocol.http;
  if (s == 'HTTPS' || s == '3') return NetworkProtocol.https;
  return NetworkProtocol.icmp;
}

/// Writes the backup to `Documents/VeloceNet-Studio/` and returns the path.
Future<String> exportTargetsFile(List<PingTarget> targets) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(
    '${docs.path}${Platform.pathSeparator}VeloceNet-Studio',
  );
  await dir.create(recursive: true);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final file =
      File('${dir.path}${Platform.pathSeparator}velocenet-targets-$stamp.json');
  await file.writeAsString(exportTargetsJson(targets), flush: true);
  return file.path;
}

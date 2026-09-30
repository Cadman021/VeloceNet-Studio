import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/ping_metric.dart';

/// RFC 4180 field escaping: quote when the value contains a comma, quote,
/// or line break, doubling embedded quotes.
///
/// Plus formula-injection defense: a cell starting with `=`, `+`, `-`, `@`,
/// tab or CR is force-quoted AND prefixed with `'`. Spreadsheet apps treat
/// a leading single quote as a text marker (not displayed, not part of the
/// value), so `=cmd|...` payloads in server names can never execute.
String _csvField(String value) {
  const risky = ['=', '+', '-', '@', '\t', '\r'];
  final needsQuote = value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r') ||
      (value.isNotEmpty && risky.contains(value[0]));
  if (!needsQuote) return value;
  var escaped = value.replaceAll('"', '""');
  if (value.isNotEmpty && risky.contains(value[0])) {
    escaped = "'$escaped";
  }
  return '"$escaped"';
}

/// Empty for never-checked targets (`epochMs == 0` would otherwise render
/// as the misleading 1970-01-01T00:00:00.000Z).
String _checkedAtIso(int epochMs) {
  if (epochMs <= 0) return '';
  return DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true)
      .toIso8601String();
}

const List<String> kMetricsCsvHeader = [
  'id',
  'name',
  'host',
  'port',
  'protocol',
  'status',
  'sent',
  'received',
  'lost',
  'loss_pct',
  'last_ms',
  'min_ms',
  'max_ms',
  'avg_ms',
  'jitter_ms',
  'checked_at_iso',
];

/// Builds a CSV snapshot of the current metrics (sorted by target id).
/// Pure function — unit tested, no I/O.
String buildMetricsCsv(Map<int, PingMetric> metrics) {
  final buffer = StringBuffer();
  buffer.writeln(kMetricsCsvHeader.join(','));
  final sorted = metrics.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final m in sorted) {
    String num(double v) => v.toStringAsFixed(2);
    final row = [
      m.id.toString(),
      _csvField(m.name),
      _csvField(m.host),
      m.port.toString(),
      _csvField(m.protocol),
      m.status.name,
      m.sentCount.toString(),
      m.receivedCount.toString(),
      m.lostCount.toString(),
      num(m.lossRate),
      num(m.lastRttMs),
      num(m.minRttMs),
      num(m.maxRttMs),
      num(m.avgRttMs),
      num(m.jitterMs),
      _csvField(_checkedAtIso(m.lastCheckedEpochMs)),
    ];
    buffer.writeln(row.join(','));
  }
  return buffer.toString();
}

/// Writes the snapshot to `Documents/VeloceNet-Studio/` and returns the
/// absolute file path. Creates the directory when missing.
Future<String> exportMetricsCsv(Map<int, PingMetric> metrics) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(
    '${docs.path}${Platform.pathSeparator}VeloceNet-Studio',
  );
  await dir.create(recursive: true);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final file = File('${dir.path}${Platform.pathSeparator}velocenet-metrics-$stamp.csv');
  await file.writeAsString(
    buildMetricsCsv(metrics),
    flush: true,
  );
  return file.path;
}

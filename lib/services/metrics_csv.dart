import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/ping_metric.dart';

/// RFC 4180 field escaping: quote when the value contains a comma, quote,
/// or line break, doubling embedded quotes.
String _csvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
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
      _csvField(DateTime.fromMillisecondsSinceEpoch(
        m.lastCheckedEpochMs,
        isUtc: true,
      ).toIso8601String()),
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

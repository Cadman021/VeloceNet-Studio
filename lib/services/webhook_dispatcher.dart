import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/alert_event.dart';
import '../state/alert_log.dart';

/// Outbound alert delivery: Telegram bot + Discord webhook.
///
/// Design notes:
/// - Fires on every recorded [AlertEvent] (transitions only, so volume is
///   inherently low), with a per-target cooldown against flapping storms.
/// - Messages are fixed-format English: ops notifications stay greppable
///   regardless of UI locale.
/// - Secrets live in `shared_preferences` in plaintext — same exposure as
///   everything else on a desktop box; documented, not solved, here.
/// - HTTP is injectable for unit tests.
class WebhookConfig {
  final bool telegramEnabled;
  final String telegramToken;
  final String telegramChatId;
  final bool discordEnabled;
  final String discordUrl;

  const WebhookConfig({
    this.telegramEnabled = false,
    this.telegramToken = '',
    this.telegramChatId = '',
    this.discordEnabled = false,
    this.discordUrl = '',
  });

  bool get canTelegram =>
      telegramEnabled &&
      telegramToken.trim().isNotEmpty &&
      telegramChatId.trim().isNotEmpty;

  bool get canDiscord =>
      discordEnabled && discordUrl.trim().startsWith('https://');
}

typedef HttpPoster = Future<bool> Function(
    Uri url, Map<String, String> headers, String body);

Future<bool> _defaultPoster(
    Uri url, Map<String, String> headers, String body) async {
  try {
    final resp = await http
        .post(url, headers: headers, body: body)
        .timeout(const Duration(seconds: 10));
    return resp.statusCode >= 200 && resp.statusCode < 300;
  } catch (_) {
    return false;
  }
}

/// Pure message formatting (unit tested).
String formatAlertMessage(AlertEvent e) {
  final icon = switch (e.severity) {
    AlertSeverity.critical => '🔴',
    AlertSeverity.warning => '🟡',
    AlertSeverity.info => '🟢',
  };
  final detail = StringBuffer('${e.from.name} → ${e.to.name}');
  if (e.rttMs > 0) detail.write(' | ${e.rttMs.toStringAsFixed(1)} ms');
  if (e.lossRate > 0) {
    detail.write(', loss ${e.lossRate.toStringAsFixed(1)}%');
  }
  return '$icon [VeloceNet] ${e.targetName}: $detail';
}

class WebhookDispatcher {
  static const cooldown = Duration(minutes: 5);

  final AlertLog log;
  final WebhookConfig Function() configOf;
  final HttpPoster _post;
  final Map<int, DateTime> _lastSent = {};
  bool _disposed = false;

  WebhookDispatcher({
    required this.log,
    required this.configOf,
    HttpPoster poster = _defaultPoster,
  }) : _post = poster {
    log.addListener(_onLog);
  }

  void _onLog() {
    if (_disposed || log.events.isEmpty) return;
    final event = log.events.first;
    unawaited(dispatch(event));
  }

  /// Sends one event to all enabled channels, honoring the cooldown.
  /// Returns true when at least one channel accepted it.
  Future<bool> dispatch(AlertEvent event, {DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final last = _lastSent[event.targetId];
    if (last != null && at.difference(last) < cooldown) {
      return false; // flapping guard
    }
    final config = configOf();
    final message = formatAlertMessage(event);
    var sent = false;
    if (config.canTelegram) {
      final ok = await _post(
        Uri.parse(
            'https://api.telegram.org/bot${config.telegramToken.trim()}/sendMessage'),
        {'Content-Type': 'application/json'},
        jsonEncode({
          'chat_id': config.telegramChatId.trim(),
          'text': message,
        }),
      );
      sent = sent || ok;
    }
    if (config.canDiscord) {
      final ok = await _post(
        Uri.parse(config.discordUrl.trim()),
        {'Content-Type': 'application/json'},
        jsonEncode({'content': message}),
      );
      sent = sent || ok;
    }
    if (sent) _lastSent[event.targetId] = at;
    return sent;
  }

  /// Sends a fixed test message (bypasses the cooldown).
  Future<bool> sendTest() {
    return _sendRaw(
      '✅ [VeloceNet] Test notification — webhooks are working.',
    );
  }

  // Same channel logic as dispatch, without cooldown bookkeeping.
  Future<bool> _sendRaw(String message) async {
    final config = configOf();
    var sent = false;
    if (config.canTelegram) {
      sent = await _post(
            Uri.parse(
                'https://api.telegram.org/bot${config.telegramToken.trim()}/sendMessage'),
            {'Content-Type': 'application/json'},
            jsonEncode({
              'chat_id': config.telegramChatId.trim(),
              'text': message,
            }),
          ) ||
          sent;
    }
    if (config.canDiscord) {
      sent = await _post(
            Uri.parse(config.discordUrl.trim()),
            {'Content-Type': 'application/json'},
            jsonEncode({'content': message}),
          ) ||
          sent;
    }
    return sent;
  }

  void dispose() {
    _disposed = true;
    log.removeListener(_onLog);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/alert_event.dart';
import '../state/alert_log.dart';

/// Outbound alert delivery: Telegram bot + Discord webhook.
///
/// Design notes:
/// - Fires on every recorded [AlertEvent] (transitions only, so volume is
///   inherently low), with a per-target cooldown against flapping storms.
/// - Message format is user-customizable (see the template setting), with a
///   fixed English default so notifications stay greppable.
/// - Secrets come from [SettingsController], backed by `SecretStore`:
///   DPAPI-protected on Windows, documented plaintext passthrough elsewhere.
/// - HTTP is injectable for unit tests.
class WebhookConfig {
  final bool telegramEnabled;
  final String telegramToken;
  final String telegramChatId;
  final bool discordEnabled;
  final String discordUrl;
  final String template;

  /// Optional `PROXY host:port` directive (see [buildProxyDirective]).
  final String? proxyDirective;

  const WebhookConfig({
    this.telegramEnabled = false,
    this.telegramToken = '',
    this.telegramChatId = '',
    this.discordEnabled = false,
    this.discordUrl = '',
    this.template = kDefaultAlertTemplate,
    this.proxyDirective,
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

/// Parses a user-typed `host:port` proxy address into an HttpClient
/// `findProxy` directive. Pure function — unit tested. Returns null when
/// proxying is disabled or the address is malformed.
///
/// NOTE: Dart's HttpClient only speaks HTTP CONNECT proxies. SOCKS proxies
/// need a manual tunnel and are out of scope (documented in Settings).
String? buildProxyDirective({required bool enabled, required String address}) {
  if (!enabled) return null;
  final parts = address.trim().split(':');
  if (parts.length != 2) return null;
  final host = parts[0].trim();
  final port = int.tryParse(parts[1].trim());
  if (host.isEmpty || port == null || port < 1 || port > 65535) {
    return null;
  }
  return 'PROXY $host:$port';
}

/// POSTs JSON through an optional HTTP proxy (direct when [proxy] is null).
Future<bool> postJson(Uri url, Map<String, String> body,
    {String? proxy}) async {
  final payload = jsonEncode(body);
  if (proxy == null) {
    try {
      final resp = await http
          .post(url,
              headers: {'Content-Type': 'application/json'}, body: payload)
          .timeout(const Duration(seconds: 10));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }
  HttpClient? client;
  try {
    client = HttpClient()..findProxy = (_) => proxy;
    final req = await client
        .postUrl(url)
        .timeout(const Duration(seconds: 10));
    req.headers.contentType = ContentType.json;
    req.write(payload);
    final resp =
        await req.close().timeout(const Duration(seconds: 10));
    await resp.drain<void>();
    return resp.statusCode >= 200 && resp.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    client?.close(force: true);
  }
}

/// Default message template. Placeholders: {icon} {name} {from} {to}
/// {detail}. Status words stay English enum names so messages remain
/// greppable/machine-parseable regardless of UI locale; operators who
/// want full localization can rewrite the whole template in Settings.
const kDefaultAlertTemplate =
    '{icon} [VeloceNet] {name}: {from} → {to}{detail}';

/// Pure message formatting (unit tested).
String formatAlertMessage(AlertEvent e, {String? template}) {
  final icon = switch (e.severity) {
    AlertSeverity.critical => '🔴',
    AlertSeverity.warning => '🟡',
    AlertSeverity.info => '🟢',
  };
  final parts = <String>[];
  if (e.rttMs > 0) parts.add('${e.rttMs.toStringAsFixed(1)} ms');
  if (e.lossRate > 0) {
    parts.add('loss ${e.lossRate.toStringAsFixed(1)}%');
  }
  final detail = parts.isEmpty ? '' : ' | ${parts.join(', ')}';
  var tpl = template?.trim() ?? '';
  if (tpl.isEmpty) tpl = kDefaultAlertTemplate;
  return tpl
      .replaceAll('{icon}', icon)
      .replaceAll('{name}', e.targetName)
      .replaceAll('{from}', e.from.name)
      .replaceAll('{to}', e.to.name)
      .replaceAll('{detail}', detail);
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
    final message = formatAlertMessage(event, template: config.template);
    var sent = false;
    if (config.canTelegram) {
      final ok = await _deliver(
        config,
        Uri.parse(
            'https://api.telegram.org/bot${config.telegramToken.trim()}/sendMessage'),
        {
          'chat_id': config.telegramChatId.trim(),
          'text': message,
        },
      );
      sent = sent || ok;
    }
    if (config.canDiscord) {
      final ok = await _deliver(
        config,
        Uri.parse(config.discordUrl.trim()),
        {'content': message},
      );
      sent = sent || ok;
    }
    if (sent) _lastSent[event.targetId] = at;
    return sent;
  }

  /// Sends one JSON body via the injected poster, or through the configured
  /// HTTP proxy when set (the fake poster in tests has no proxy support by
  /// design — proxy parsing itself is covered by unit tests).
  Future<bool> _deliver(
      WebhookConfig config, Uri url, Map<String, String> body) async {
    final proxy = config.proxyDirective;
    if (proxy != null) return postJson(url, body, proxy: proxy);
    return _post(url, {'Content-Type': 'application/json'}, jsonEncode(body));
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
      sent = await _deliver(
            config,
            Uri.parse(
                'https://api.telegram.org/bot${config.telegramToken.trim()}/sendMessage'),
            {
              'chat_id': config.telegramChatId.trim(),
              'text': message,
            },
          ) ||
          sent;
    }
    if (config.canDiscord) {
      sent = await _deliver(
            config,
            Uri.parse(config.discordUrl.trim()),
            {'content': message},
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

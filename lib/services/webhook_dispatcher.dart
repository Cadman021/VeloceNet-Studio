import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/validation/host_validator.dart' show isValidDiscordWebhookUrl;
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

  bool get canDiscord => discordEnabled && isValidDiscordWebhookUrl(discordUrl);
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
    final req = await client.postUrl(url).timeout(const Duration(seconds: 10));
    req.headers.contentType = ContentType.json;
    req.write(payload);
    final resp = await req.close().timeout(const Duration(seconds: 10));
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

/// One queued outbound message: how to render it for a given delivery
/// delay, and how to send one rendered variant.
class _OutboxEntry {
  final String Function(Duration delayedBy) render;
  final Future<bool> Function(String message) send;
  final DateTime firstFailedAt;
  int attempts = 0;
  DateTime nextRetry;

  _OutboxEntry({
    required this.render,
    required this.send,
    required this.firstFailedAt,
  }) : nextRetry = firstFailedAt.add(const Duration(minutes: 1));
}

class WebhookDispatcher {
  static const cooldown = Duration(minutes: 5);
  static const _maxOutbox = 100;
  static const _maxOutboxAge = Duration(hours: 24);
  static const _backoffMinutes = [1, 2, 4, 8, 15];

  final AlertLog log;
  final WebhookConfig Function() configOf;
  final HttpPoster _post;
  // Cooldown is per (target, event kind): a recovery must never be
  // swallowed just because the matching down-alert went out recently.
  final Map<String, DateTime> _lastSent = {};
  final List<_OutboxEntry> _outbox = [];
  Timer? _flushTimer;
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

  static String _cooldownKey(AlertEvent e) => '${e.targetId}:${e.to.index}';

  /// Sends one event to all enabled channels, honoring the cooldown.
  /// Returns true when at least one channel accepted it. Failures land in
  /// the outbox for retry instead of being lost (e.g. during an internet
  /// outage — the very moment alerts matter most).
  Future<bool> dispatch(AlertEvent event, {DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final key = _cooldownKey(event);
    final last = _lastSent[key];
    if (last != null && at.difference(last) < cooldown) {
      return false; // flapping guard (same event kind only)
    }
    final config = configOf();
    String render(Duration delayedBy) {
      var text = formatAlertMessage(event, template: config.template);
      if (delayedBy >= const Duration(minutes: 2)) {
        text += '\n(⏳ delayed ${delayedBy.inMinutes}m — connectivity was down)';
      }
      return text;
    }

    var sent = false;
    if (config.canTelegram) {
      final url = Uri.parse(
          'https://api.telegram.org/bot${config.telegramToken.trim()}/sendMessage');
      final chatId = config.telegramChatId.trim();
      Future<bool> send(String message) =>
          _deliver(config, url, {'chat_id': chatId, 'text': message});
      if (await send(render(Duration.zero))) {
        sent = true;
      } else {
        _enqueue(_OutboxEntry(render: render, send: send, firstFailedAt: at));
      }
    }
    if (config.canDiscord) {
      final url = Uri.parse(config.discordUrl.trim());
      Future<bool> send(String message) =>
          _deliver(config, url, {'content': message});
      if (await send(render(Duration.zero))) {
        sent = true;
      } else {
        _enqueue(_OutboxEntry(render: render, send: send, firstFailedAt: at));
      }
    }
    if (sent) _lastSent[key] = at;
    return sent;
  }

  void _enqueue(_OutboxEntry entry) {
    if (_outbox.length >= _maxOutbox) _outbox.removeAt(0);
    _outbox.add(entry);
    _flushTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(flushOutbox()),
    );
  }

  /// Retries due outbox entries. Exposed for tests (pass `now`).
  @visibleForTesting
  Future<void> flushOutbox({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final done = <_OutboxEntry>[];
    for (final entry in List.of(_outbox)) {
      if (_disposed) break;
      if (at.isBefore(entry.nextRetry)) continue;
      if (at.difference(entry.firstFailedAt) > _maxOutboxAge) {
        done.add(entry); // stale: drop silently, it outlived relevance
        continue;
      }
      bool ok = false;
      try {
        ok = await entry.send(entry.render(at.difference(entry.firstFailedAt)));
      } catch (_) {
        ok = false;
      }
      if (ok) {
        done.add(entry);
      } else {
        entry.attempts++;
        final step = entry.attempts < _backoffMinutes.length
            ? _backoffMinutes[entry.attempts]
            : _backoffMinutes.last;
        entry.nextRetry = at.add(Duration(minutes: step));
      }
    }
    _outbox.removeWhere(done.contains);
    if (_outbox.isEmpty) {
      _flushTimer?.cancel();
      _flushTimer = null;
    }
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
    _flushTimer?.cancel();
    _flushTimer = null;
    log.removeListener(_onLog);
  }
}

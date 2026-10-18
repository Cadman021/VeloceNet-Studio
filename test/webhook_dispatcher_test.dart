import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/alert_event.dart';
import 'package:netstudio/models/ping_metric.dart';
import 'package:netstudio/services/webhook_dispatcher.dart';
import 'package:netstudio/state/alert_log.dart';

AlertEvent _event(int targetId, TargetStatus from, TargetStatus to) {
  return AlertEvent(
    id: targetId,
    targetId: targetId,
    targetName: 'web',
    from: from,
    to: to,
    timestamp: DateTime.utc(2026, 9, 30, 12, 0),
    rttMs: 45.2,
    lossRate: 100.0,
  );
}

void main() {
  group('formatAlertMessage', () {
    test('critical offline includes icon, transition and numbers', () {
      final msg = formatAlertMessage(
          _event(1, TargetStatus.online, TargetStatus.offline));
      expect(msg, contains('🔴'));
      expect(msg, contains('[VeloceNet]'));
      expect(msg, contains('online → offline'));
      expect(msg, contains('45.2 ms'));
      expect(msg, contains('100.0%'));
    });

    test('recovery is green without loss detail', () {
      final msg = formatAlertMessage(
          _event(1, TargetStatus.offline, TargetStatus.online));
      expect(msg, contains('🟢'));
      expect(msg, contains('offline → online'));
    });

    test('custom template arranges placeholders', () {
      final msg = formatAlertMessage(
        _event(1, TargetStatus.online, TargetStatus.offline),
        template: '[{to}] {name} was {from}',
      );
      expect(msg, '[offline] web was online');
    });

    test('empty template falls back to default', () {
      final msg = formatAlertMessage(
        _event(1, TargetStatus.online, TargetStatus.offline),
        template: '   ',
      );
      expect(msg, contains('[VeloceNet]'));
    });
  });

  group('WebhookDispatcher', () {
    const config = WebhookConfig(
      telegramEnabled: true,
      telegramToken: 'tok',
      telegramChatId: '1',
      discordEnabled: true,
      discordUrl: 'https://discord.com/api/webhooks/x',
    );

    test('posts to both channels with JSON bodies', () async {
      final calls = <String>[];
      final log = AlertLog();
      final dispatcher = WebhookDispatcher(
        log: log,
        configOf: () => config,
        poster: (url, headers, body) async {
          calls.add('${url.host}${url.path}::$body');
          return true;
        },
      );
      final ok = await dispatcher.dispatch(
        _event(7, TargetStatus.online, TargetStatus.offline),
        now: DateTime.utc(2026, 9, 30, 12, 0),
      );
      expect(ok, isTrue);
      expect(calls, hasLength(2));
      expect(calls[0], contains('api.telegram.org'));
      expect(calls[0], contains('chat_id'));
      expect(calls[1], contains('discord.com'));
      // Listener path: recording an event triggers a dispatch attempt.
      log.noteTransition(
        targetId: 7,
        targetName: 'web',
        from: TargetStatus.online,
        to: TargetStatus.offline,
        rttMs: 1.0,
        lossRate: 100.0,
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(4));
      dispatcher.dispose();
      log.dispose();
    });

    test('cooldown is per event kind: recovery is never swallowed', () async {
      int calls = 0;
      final log = AlertLog();
      final dispatcher = WebhookDispatcher(
        log: log,
        configOf: () => config,
        poster: (_, __, ___) async {
          calls++;
          return true;
        },
      );
      final t0 = DateTime.utc(2026, 9, 30, 12, 0);
      // Down at :00 goes out…
      expect(
          await dispatcher.dispatch(
              _event(3, TargetStatus.online, TargetStatus.offline),
              now: t0),
          isTrue);
      // …recovery at :01 is a different kind and must NOT be suppressed,
      // or the user would think the host is still down.
      expect(
          await dispatcher.dispatch(
              _event(3, TargetStatus.offline, TargetStatus.online),
              now: t0.add(const Duration(minutes: 1))),
          isTrue);
      // …but the same kind within 5 minutes still is.
      expect(
          await dispatcher.dispatch(
              _event(3, TargetStatus.online, TargetStatus.offline),
              now: t0.add(const Duration(minutes: 2))),
          isFalse);
      expect(
          await dispatcher.dispatch(
              _event(3, TargetStatus.online, TargetStatus.offline),
              now: t0.add(const Duration(minutes: 6))),
          isTrue);
      expect(calls, 6); // 2 channels x 3 accepted sends
      dispatcher.dispose();
      log.dispose();
    });

    test('failed sends queue up and retry with delay annotation', () async {
      final sentBodies = <String>[];
      int attempts = 0;
      final log = AlertLog();
      final dispatcher = WebhookDispatcher(
        log: log,
        configOf: () => config,
        poster: (_, __, body) async {
          attempts++;
          if (attempts < 3) return false; // outage for the first two tries
          sentBodies.add(body);
          return true;
        },
      );
      final t0 = DateTime.utc(2026, 9, 30, 12, 0);
      // Both channels fail twice: nothing delivered, two outbox entries.
      expect(
          await dispatcher.dispatch(
              _event(5, TargetStatus.online, TargetStatus.offline),
              now: t0),
          isFalse);
      // Too early: backoff not elapsed.
      await dispatcher.flushOutbox(now: t0.add(const Duration(seconds: 30)));
      expect(sentBodies, isEmpty);
      // First retry due at +1m, still failing; second at +3m succeeds with
      // the delay annotation (both channels share the entry path here,
      // so both bodies carry it).
      await dispatcher.flushOutbox(now: t0.add(const Duration(minutes: 2)));
      expect(sentBodies, hasLength(2));
      expect(sentBodies.first, contains('delayed'));
      dispatcher.dispose();
      log.dispose();
    });

    test('discord webhook URL must be discord-owned https', () {
      const good = WebhookConfig(
        discordEnabled: true,
        discordUrl: 'https://discord.com/api/webhooks/123/abc',
      );
      expect(good.canDiscord, isTrue);
      const ptb = WebhookConfig(
        discordEnabled: true,
        discordUrl: 'https://ptb.discord.com/api/webhooks/123/abc',
      );
      expect(ptb.canDiscord, isTrue);
      for (final bad in [
        'https://evil.com/api/webhooks/123/abc',
        'https://discord.com.evil.com/api/webhooks/123',
        'http://discord.com/api/webhooks/123/abc',
        'not a url',
        '',
      ]) {
        expect(
          WebhookConfig(discordEnabled: true, discordUrl: bad).canDiscord,
          isFalse,
          reason: bad,
        );
      }
    });

    test('proxy directive parsing', () {
      expect(buildProxyDirective(enabled: false, address: '127.0.0.1:8080'),
          isNull);
      expect(buildProxyDirective(enabled: true, address: '127.0.0.1:8080'),
          'PROXY 127.0.0.1:8080');
      expect(buildProxyDirective(enabled: true, address: 'no-port'), isNull);
      expect(buildProxyDirective(enabled: true, address: 'h:99999'), isNull);
      expect(buildProxyDirective(enabled: true, address: ''), isNull);
    });

    test('disabled channels send nothing', () async {
      int calls = 0;
      final log = AlertLog();
      final dispatcher = WebhookDispatcher(
        log: log,
        configOf: () => const WebhookConfig(),
        poster: (_, __, ___) async {
          calls++;
          return true;
        },
      );
      expect(
          await dispatcher
              .dispatch(_event(1, TargetStatus.online, TargetStatus.offline)),
          isFalse);
      expect(calls, 0);
      dispatcher.dispose();
      log.dispose();
    });
  });
}

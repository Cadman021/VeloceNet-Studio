import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/autostart_service.dart';
import '../../services/update_checker.dart';
import '../../services/webhook_dispatcher.dart' show buildProxyDirective;
import '../app_info.dart';
import 'secret_store.dart';

/// App-wide settings: theme mode + locale, persisted locally.
/// Default: English + System theme (per project decision).
class SettingsController extends ChangeNotifier {
  /// Backing store for webhook secrets (DPAPI on Windows, documented
  /// plaintext passthrough elsewhere). Injectable for unit tests.
  final SecretStore _secrets;
  SettingsController({SecretStore? secrets, AutostartService? autostart})
      : _secrets = secrets ?? PlatformSecretStore(),
        _autostart = autostart ?? AutostartService();

  static const _kTheme = 'settings.themeMode';
  static const _kLocale = 'settings.locale';
  static const _kTgEnabled = 'settings.tgEnabled';
  static const _kTgToken = 'settings.tgToken';
  static const _kTgChat = 'settings.tgChat';
  static const _kDcEnabled = 'settings.dcEnabled';
  static const _kDcUrl = 'settings.dcUrl';
  static const _kNtfyEnabled = 'settings.ntfyEnabled';
  static const _kNtfyServer = 'settings.ntfyServer';
  static const _kNtfyTopic = 'settings.ntfyTopic';
  static const _kGenericEnabled = 'settings.genericEnabled';
  static const _kGenericUrl = 'settings.genericUrl';
  static const _kWhTemplate = 'settings.whTemplate';
  static const _kProxyEnabled = 'settings.proxyEnabled';
  static const _kProxy = 'settings.proxy';
  static const _kTray = 'settings.tray';
  static const _kAutostart = 'settings.autostart';
  static const _kAlertOfflineAfter = 'settings.alertOfflineAfter';
  static const _kAlertRecoverAfter = 'settings.alertRecoverAfter';
  static const _kUpdateAuto = 'settings.updateAuto';
  static const _kLastUpdateCheck = 'settings.lastUpdateCheck';
  static const _kKnownLatest = 'settings.knownLatest';
  static const _kKnownNotes = 'settings.knownNotes';
  static const _kDismissedUpdate = 'settings.dismissedUpdate';

  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = const Locale('en');

  // Alert webhooks (Telegram bot + Discord webhook). The three secrets
  // below are DPAPI-protected on Windows and plaintext-passthrough
  // elsewhere (see secret_store.dart + SECURITY.md). The toggles stay in
  // shared_preferences (non-sensitive).
  //
  // Non-null [secretWarning] means the last save landed unprotected and
  // the webhooks section surfaces it (silent fallback was a real bug).
  String? secretWarning;
  bool telegramEnabled = false;
  String telegramToken = '';
  String telegramChatId = '';
  bool discordEnabled = false;
  String discordUrl = '';
  // ntfy (https://ntfy.sh or a self-hosted server). The server defaults to
  // the public instance when blank; topic is validated before enabling.
  bool ntfyEnabled = false;
  String ntfyServer = '';
  String ntfyTopic = '';
  // Generic webhook: any http(s) endpoint receiving a JSON envelope.
  // The URL may be sensitive (it can embed a token), so it is stored via
  // the same protected SecretStore as the other channels.
  bool genericEnabled = false;
  String genericUrl = '';
  // Custom alert template (empty = built-in default). Placeholders:
  // {icon} {name} {from} {to} {detail}.
  String webhookTemplate = '';
  // Optional HTTP proxy for webhook delivery ("host:port", empty = direct).
  // Dart's HttpClient only speaks HTTP CONNECT proxies — SOCKS is out of
  // scope (documented in the webhook settings UI).
  bool proxyEnabled = false;
  String proxyAddress = '';
  // Minimize to the system tray on window close instead of quitting.
  // Monitoring keeps running in the background; Quit lives in the tray menu.
  bool trayEnabled = true;

  // Launch at login. The OS entry is the source of truth at load time;
  // the persisted flag only records the user's intent so a transient
  // registry/FS failure doesn't silently flip the toggle.
  final AutostartService _autostart;
  bool autostartEnabled = false;

  /// Whether launch-at-login can be configured here (Windows/Linux only).
  bool get autostartSupported => AutostartService.isSupported;

  // Alert trip points, mirrored to the prober (native engine + fallback):
  // offline after N consecutive failures, recovery after M consecutive
  // successes. Same defaults/semantics as stats.rs.
  int alertOfflineAfter = 3;
  int alertRecoverAfter = 2;
  // Automatic (startup) update checks. Manual "check now" taps always run
  // regardless — this toggle is the offline-friendly opt-out.
  bool updateCheckEnabled = true;

  // Update discovery state. `latestKnownVersion` is null when up to date
  // (or never successfully checked).
  bool checkingUpdates = false;
  String? latestKnownVersion;
  String latestUpdateNotes = '';
  DateTime? lastUpdateCheck;
  String? dismissedUpdateVersion;

  /// Whether the startup update dialog should be shown: a known newer
  /// version that the user hasn't dismissed yet (dismissals are per
  /// version, so a *newer* release re-triggers exactly once).
  bool get shouldShowUpdateDialog {
    final latest = latestKnownVersion;
    if (latest == null) return false;
    final dismissed = dismissedUpdateVersion;
    if (dismissed == null) return true;
    return compareVersions(dismissed, latest) < 0;
  }

  Future<void> dismissUpdate(String version) async {
    dismissedUpdateVersion = version;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDismissedUpdate, version);
    } catch (_) {}
  }

  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;

  bool get isDark => _themeMode == ThemeMode.dark;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final theme = prefs.getString(_kTheme);
      switch (theme) {
        case 'light':
          _themeMode = ThemeMode.light;
          break;
        case 'dark':
          _themeMode = ThemeMode.dark;
          break;
        default:
          _themeMode = ThemeMode.system;
      }
      final loc = prefs.getString(_kLocale);
      _locale =
          allowedLocales.contains(loc) ? Locale(loc!) : const Locale('en');
      telegramEnabled = prefs.getBool(_kTgEnabled) ?? false;
      discordEnabled = prefs.getBool(_kDcEnabled) ?? false;
      ntfyEnabled = prefs.getBool(_kNtfyEnabled) ?? false;
      ntfyServer = prefs.getString(_kNtfyServer) ?? '';
      ntfyTopic = prefs.getString(_kNtfyTopic) ?? '';
      genericEnabled = prefs.getBool(_kGenericEnabled) ?? false;
      // Parallel: three sequential timeouts would stall startup 3x.
      final secrets = await Future.wait([
        _readSecret(_kTgToken),
        _readSecret(_kTgChat),
        _readSecret(_kDcUrl),
        _readSecret(_kGenericUrl),
      ]);
      telegramToken = secrets[0];
      telegramChatId = secrets[1];
      discordUrl = secrets[2];
      genericUrl = secrets[3];
      webhookTemplate = prefs.getString(_kWhTemplate) ?? '';
      proxyEnabled = prefs.getBool(_kProxyEnabled) ?? false;
      proxyAddress = prefs.getString(_kProxy) ?? '';
      trayEnabled = prefs.getBool(_kTray) ?? true;
      autostartEnabled = (prefs.getBool(_kAutostart) ?? false) &&
          await _autostart.isEnabled();
      alertOfflineAfter = (prefs.getInt(_kAlertOfflineAfter) ?? 3).clamp(1, 20);
      alertRecoverAfter = (prefs.getInt(_kAlertRecoverAfter) ?? 2).clamp(1, 20);
      updateCheckEnabled = prefs.getBool(_kUpdateAuto) ?? true;
      latestKnownVersion = prefs.getString(_kKnownLatest);
      latestUpdateNotes = prefs.getString(_kKnownNotes) ?? '';
      dismissedUpdateVersion = prefs.getString(_kDismissedUpdate);
      final lastMs = prefs.getInt(_kLastUpdateCheck);
      lastUpdateCheck =
          lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
    } catch (_) {
      // Keep defaults on storage failure.
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kTheme,
        mode == ThemeMode.light
            ? 'light'
            : mode == ThemeMode.dark
                ? 'dark'
                : 'system',
      );
    } catch (_) {}
  }

  /// Reads a secret via [SecretStore]. Any failure degrades to '' — the
  /// app keeps working, webhooks just stay unconfigured. Every store call
  /// is timeout-bounded so a wedged backend delays startup by seconds,
  /// never hangs it forever.
  static const _secretTimeout = Duration(seconds: 3);

  Future<String> _readSecret(String key) async {
    try {
      return await _secrets
          .read(key)
          .timeout(_secretTimeout)
          .then((v) => v ?? '');
    } catch (_) {
      return '';
    }
  }

  /// Writes one secret, returning false when protection was expected but
  /// failed (value landed as plaintext). Delete of an empty value always
  /// "succeeds".
  Future<bool> _writeSecret(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _secrets.delete(key).timeout(_secretTimeout);
        return true;
      }
      return await _secrets.writeProtected(key, value).timeout(_secretTimeout);
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveWebhookPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTgEnabled, telegramEnabled);
      await prefs.setBool(_kDcEnabled, discordEnabled);
      await prefs.setBool(_kNtfyEnabled, ntfyEnabled);
      await prefs.setString(_kNtfyServer, ntfyServer);
      await prefs.setString(_kNtfyTopic, ntfyTopic);
      await prefs.setBool(_kGenericEnabled, genericEnabled);
      await prefs.setString(_kWhTemplate, webhookTemplate);
    } catch (_) {}
    final results = await Future.wait([
      _writeSecret(_kTgToken, telegramToken),
      _writeSecret(_kTgChat, telegramChatId),
      _writeSecret(_kDcUrl, discordUrl),
      _writeSecret(_kGenericUrl, genericUrl),
    ]);
    final ok = !results.contains(false);
    if ((ok && secretWarning != null) || (!ok && secretWarning == null)) {
      secretWarning = ok ? null : 'unprotected';
      notifyListeners();
    }
  }

  Future<void> setTelegram(
      {bool? enabled, String? token, String? chatId}) async {
    if (enabled != null) telegramEnabled = enabled;
    if (token != null) telegramToken = token;
    if (chatId != null) telegramChatId = chatId;
    notifyListeners();
    await _saveWebhookPrefs();
  }

  Future<void> setDiscord({bool? enabled, String? url}) async {
    if (enabled != null) discordEnabled = enabled;
    if (url != null) discordUrl = url;
    notifyListeners();
    await _saveWebhookPrefs();
  }

  Future<void> setNtfy(
      {bool? enabled, String? server, String? topic}) async {
    if (enabled != null) ntfyEnabled = enabled;
    if (server != null) ntfyServer = server;
    if (topic != null) ntfyTopic = topic;
    notifyListeners();
    await _saveWebhookPrefs();
  }

  Future<void> setGenericWebhook({bool? enabled, String? url}) async {
    if (enabled != null) genericEnabled = enabled;
    if (url != null) genericUrl = url;
    notifyListeners();
    await _saveWebhookPrefs();
  }

  Future<void> setWebhookTemplate(String template) async {
    webhookTemplate = template;
    notifyListeners();
    await _saveWebhookPrefs();
  }

  /// Batch save for debounced text fields (one DPAPI+prefs round instead
  /// of one per keystroke — see the settings screen).
  Future<void> saveSecretFields({
    String? token,
    String? chatId,
    String? url,
    String? template,
    String? proxyAddress,
    String? ntfyServer,
    String? ntfyTopic,
    String? genericUrl,
  }) async {
    if (token != null) telegramToken = token;
    if (chatId != null) telegramChatId = chatId;
    if (url != null) discordUrl = url;
    if (template != null) webhookTemplate = template;
    if (proxyAddress != null) this.proxyAddress = proxyAddress;
    if (ntfyServer != null) this.ntfyServer = ntfyServer;
    if (ntfyTopic != null) this.ntfyTopic = ntfyTopic;
    if (genericUrl != null) this.genericUrl = genericUrl;
    notifyListeners();
    await _saveWebhookPrefs();
  }

  Future<void> setTrayEnabled(bool value) async {
    trayEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTray, trayEnabled);
    } catch (_) {}
  }

  /// Enables/disables launch-at-login. Only updates the in-memory flag when
  /// the OS entry actually changed, so the toggle never claims a state the
  /// system didn't accept (locked registry, read-only home).
  Future<void> setAutostartEnabled(bool value) async {
    final ok = await _autostart.setEnabled(value);
    if (!ok) {
      notifyListeners(); // re-render so the switch snaps back
      return;
    }
    autostartEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutostart, autostartEnabled);
    } catch (_) {}
  }

  Future<void> setAlertThresholds(
      {int? offlineAfter, int? recoverAfter}) async {
    if (offlineAfter != null) {
      alertOfflineAfter = offlineAfter.clamp(1, 20);
    }
    if (recoverAfter != null) {
      alertRecoverAfter = recoverAfter.clamp(1, 20);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kAlertOfflineAfter, alertOfflineAfter);
      await prefs.setInt(_kAlertRecoverAfter, alertRecoverAfter);
    } catch (_) {}
  }

  Future<void> setUpdateCheckEnabled(bool value) async {
    updateCheckEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kUpdateAuto, updateCheckEnabled);
    } catch (_) {}
  }

  /// Checks GitHub Releases for a newer version.
  ///
  /// Returns true = update available, false = up to date, null = the check
  /// itself failed (offline/rate-limited). Auto checks are throttled to
  /// once a day and skipped entirely when the user opted out; manual taps
  /// pass `force: true`. Honors the configured webhook proxy (same one the
  /// user already trusts for Telegram/Discord). Never throws.
  Future<bool?> checkForUpdates(
      {bool force = false, http.Client? client}) async {
    final now = DateTime.now();
    bool knownNewer() {
      return latestKnownVersion != null &&
          compareVersions(latestKnownVersion!, AppInfo.kAppVersion) > 0;
    }

    if (!force && !updateCheckEnabled) {
      return knownNewer();
    }
    if (!force && !shouldAutoCheck(lastUpdateCheck, now)) {
      return knownNewer();
    }
    checkingUpdates = true;
    notifyListeners();
    try {
      final info = await fetchLatestRelease(
        client: client,
        proxyDirective: buildProxyDirective(
          enabled: proxyEnabled,
          address: proxyAddress,
        ),
      );
      lastUpdateCheck = now;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_kLastUpdateCheck, now.millisecondsSinceEpoch);
        if (info != null &&
            compareVersions(info.version, AppInfo.kAppVersion) > 0) {
          latestKnownVersion = info.version;
          // Cap stored notes: release bodies can be long, the dialog only
          // shows a preview.
          final notes = info.notes.trim();
          latestUpdateNotes =
              notes.length > 2000 ? '${notes.substring(0, 2000)}…' : notes;
          await prefs.setString(_kKnownLatest, info.version);
          await prefs.setString(_kKnownNotes, latestUpdateNotes);
        } else if (info != null) {
          latestKnownVersion = null;
          latestUpdateNotes = '';
          await prefs.remove(_kKnownLatest);
          await prefs.remove(_kKnownNotes);
        }
      } catch (_) {}
      if (info == null) return null;
      return compareVersions(info.version, AppInfo.kAppVersion) > 0;
    } finally {
      checkingUpdates = false;
      notifyListeners();
    }
  }

  Future<void> setProxy({bool? enabled, String? address}) async {
    if (enabled != null) proxyEnabled = enabled;
    if (address != null) proxyAddress = address;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kProxyEnabled, proxyEnabled);
      await prefs.setString(_kProxy, proxyAddress);
    } catch (_) {}
  }

  static const allowedLocales = ['en', 'fa', 'ru', 'zh'];

  Future<void> setLocale(Locale locale) async {
    if (!allowedLocales.contains(locale.languageCode)) return;
    _locale = Locale(locale.languageCode);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLocale, _locale.languageCode);
    } catch (_) {}
  }
}

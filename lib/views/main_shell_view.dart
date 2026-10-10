import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../core/i18n/app_strings.dart';
import '../core/theme/theme_x.dart';
import '../core/settings/settings_controller.dart';
import '../core/theme/app_colors.dart';
import '../models/ping_target.dart';
import '../services/webhook_dispatcher.dart';
import '../state/ping_matrix_controller.dart';
import 'bandwidth/bandwidth_screen.dart';
import 'dnslookup/dnslookup_screen.dart';
import 'mtr/mtr_screen.dart';
import 'ping_matrix/ping_matrix_screen.dart';
import 'portscan/portscan_screen.dart';
import 'settings/settings_screen.dart';
import 'settings/update_available_dialog.dart';
import 'traceroute/traceroute_screen.dart';
import 'warp/warp_controller.dart';
import 'warp/warp_screen.dart';

class MainShellView extends StatefulWidget {
  final SettingsController settings;
  const MainShellView({super.key, required this.settings});

  @override
  State<MainShellView> createState() => _MainShellViewState();
}

class _MainShellViewState extends State<MainShellView>
    with WindowListener {
  int _selectedIndex = 0;
  late final PingMatrixController _pingController;
  late final WarpController _warpController;
  late final WebhookDispatcher _webhooks;
  bool _trayReady = false;
  TrayIcon? _trayIcon;
  Timer? _updateCheckTimer;

  @override
  void initState() {
    super.initState();
    _pingController = PingMatrixController();
    _pingController.init();
    _warpController = WarpController();
    // Live alert delivery: reads the current webhook config on every event,
    // so toggling in Settings takes effect without restarts.
    _webhooks = WebhookDispatcher(
      log: _pingController.alertLog,
      configOf: () => WebhookConfig(
        telegramEnabled: widget.settings.telegramEnabled,
        telegramToken: widget.settings.telegramToken,
        telegramChatId: widget.settings.telegramChatId,
        discordEnabled: widget.settings.discordEnabled,
        discordUrl: widget.settings.discordUrl,
        template: widget.settings.webhookTemplate.isEmpty
            ? kDefaultAlertTemplate
            : widget.settings.webhookTemplate,
        proxyDirective: buildProxyDirective(
          enabled: widget.settings.proxyEnabled,
          address: widget.settings.proxyAddress,
        ),
      ),
    );
    widget.settings.addListener(_onSettingsChanged);
    _setupTray();
    // Daily-throttled update check, delayed so it never contends with
    // first-frame work. Failures stay silent (see _UpdateRow for the
    // manual path); a find surfaces once as a dialog (per released
    // version) plus persistently in the About section. Cancellable so
    // widget tests (and fast quits) never see a pending timer.
    _updateCheckTimer = Timer(const Duration(seconds: 8), () async {
      if (!mounted) return;
      await widget.settings.checkForUpdates();
      if (!mounted) return;
      await UpdateAvailableDialog.showIfNeeded(context, widget.settings);
    });
  }

  @override
  void dispose() {
    _updateCheckTimer?.cancel();
    widget.settings.removeListener(_onSettingsChanged);
    _teardownTray();
    _webhooks.dispose();
    _pingController.dispose();
    _warpController.dispose();
    super.dispose();
  }

  /// Applies tray on/off transitions at runtime (toggle lives in Settings).
  void _onSettingsChanged() {
    if (!mounted) return;
    if (widget.settings.trayEnabled && !_trayReady) {
      _setupTray();
    } else if (!widget.settings.trayEnabled && _trayReady) {
      _teardownTray();
    } else if (widget.settings.trayEnabled) {
      _refreshTrayMenu();
    }
  }

  /// Best-effort tray setup (tray_manager 0.8 native API): any step may
  /// throw on platforms without tray support (or in widget tests without
  /// plugins) — the app must work the same without it.
  Future<void> _setupTray() async {
    if (!widget.settings.trayEnabled || _trayIcon != null) return;
    // Widget tests have no window/tray plugins: some plugin calls never
    // complete there (instead of throwing), which would hang pumpWidget.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      await windowManager.ensureInitialized();
      final icon = TrayIcon.create();
      if (icon == null) return; // tray not supported here
      // The PNG must be a bundled flutter asset (see pubspec); a missing
      // asset yields a null image and an invisible icon.
      final image = ImageAsset.fromAsset('assets/icons/app_icon.png');
      if (image == null) return;
      _trayIcon = icon;
      icon.icon = image;
      icon.setTooltip('VeloceNet-Studio');
      // New icons start hidden — without this the tray entry exists but
      // is never shown.
      icon.setVisible(true);
      icon.addListener((event) {
        if (event is TrayIconClickedEvent) _toggleWindow();
      });
      await windowManager.setPreventClose(true);
      windowManager.removeListener(this);
      windowManager.addListener(this);
      _trayReady = true;
      await _refreshTrayMenu();
    } catch (_) {
      _trayIcon = null;
      _trayReady = false;
    }
  }

  Future<void> _refreshTrayMenu() async {
    final icon = _trayIcon;
    if (icon == null ||
        !_trayReady ||
        !widget.settings.trayEnabled) {
      return;
    }
    try {
      final strings = AppStrings(widget.settings.locale);
      final visible = await windowManager.isVisible();
      final menu = Menu.create();
      if (menu == null) return;
      final toggle = MenuItem.createWithLabelAndType(
        visible ? strings.get('trayHide') : strings.get('trayShow'),
        MenuItemType.normal,
      );
      toggle?.addListener((event) {
        if (event is MenuItemClickedEvent) _toggleWindow();
      });
      if (toggle != null) menu.addItem(toggle);
      menu.addSeparator();
      final quit = MenuItem.createWithLabelAndType(
        strings.get('trayQuit'),
        MenuItemType.normal,
      );
      quit?.addListener((event) {
        if (event is MenuItemClickedEvent) windowManager.destroy();
      });
      if (quit != null) menu.addItem(quit);
      icon.setContextMenu(menu);
    } catch (_) {}
  }

  Future<void> _teardownTray() async {
    _trayReady = false;
    try {
      windowManager.removeListener(this);
      await windowManager.setPreventClose(false);
      _trayIcon?.dispose();
    } catch (_) {}
    _trayIcon = null;
  }

  Future<void> _toggleWindow() async {
    try {
      if (await windowManager.isVisible()) {
        await windowManager.hide();
      } else {
        await windowManager.show();
      }
      await _refreshTrayMenu();
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    // With tray mode, closing hides to the tray (monitoring continues);
    // otherwise the window really closes. The `_trayReady` check matters
    // on Linux desktops without an appindicator host: there the tray icon
    // never materializes, and hiding would leave a ghost process with no
    // window and no tray entry — so fall through to a real close.
    if (!widget.settings.trayEnabled || !_trayReady) {
      await windowManager.destroy();
      return;
    }
    await windowManager.hide();
    await _refreshTrayMenu();
  }

  void _addWarpEndpointsToMatrix(List<Map<String, dynamic>> endpoints) {
    // Assign fresh IDs above the max existing target id.
    int nextId = _pingController.targets.isEmpty
        ? 1
        : _pingController.targets.map((t) => t.id).reduce((a, b) => a > b ? a : b) + 1;
    for (final e in endpoints) {
      final ip = e['ip']?.toString() ?? '';
      if (ip.isEmpty || ip.length > 253) continue;
      final port = (e['port'] as num?)?.toInt() ?? 0;
      if (port < 1 || port > 65535) continue;
      final rank = (e['rank'] as num?)?.toInt() ?? 0;
      final label = rank > 0 ? 'Warp #$rank ($ip)' : 'Warp ($ip)';
      _pingController.addTarget(PingTarget(
        id: nextId++,
        name: label,
        host: ip,
        port: port,
        protocol: NetworkProtocol.tcp,
        intervalMs: 1200,
        timeoutMs: 2000,
      ));
    }
    setState(() => _selectedIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(widget.settings.locale);
    final isFa = widget.settings.locale.languageCode == 'fa';
    // Honest capability label: native ICMP tracing exists on Windows only;
    // elsewhere the engine runs TCP probes and the system tracer is used.
    final platformLabel = Platform.isWindows
        ? 'Windows x64 Native Core'
        : Platform.isLinux
            ? 'Linux Core (TCP mode)'
            : Platform.isMacOS
                ? 'macOS Core (TCP mode)'
                : 'Native Core';
    return Scaffold(
      body: Directionality(
        textDirection: isFa ? TextDirection.rtl : TextDirection.ltr,
        child: Row(
          children: [
            // Sidebar Navigation (theme-aware)
            Container(
              width: 250,
              decoration: BoxDecoration(
                color: context.surfaceColor,
                border: Border(
                  left: BorderSide(color: context.borderColor, width: 1),
                ),
              ),
              child: Column(
                children: [
                  // Brand Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [AppColors.primary, AppColors.cyan],
                            ),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primary.withValues(alpha: 0.4),
                                blurRadius: 10,
                                spreadRadius: -2,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.hub_rounded, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                strings.get('appTitle'),
                                style: TextStyle(
                                  color: context.textPrimaryColor,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: -0.5,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                              Text(
                                strings.get('appSubtitle'),
                                style: TextStyle(
                                  color: context.textMutedColor,
                                  fontSize: 11,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(color: context.borderColor, height: 1),
                  const SizedBox(height: 12),
                  // Navigation Items
                  AnimatedBuilder(
                    animation: _pingController,
                    builder: (context, _) {
                      return _buildNavItem(
                        index: 0,
                        icon: Icons.grid_view_rounded,
                        label: strings.get('pingMatrix'),
                        badge: '${_pingController.targets.length}',
                      );
                    },
                  ),
                  _buildNavItem(
                    index: 1,
                    icon: Icons.alt_route_rounded,
                    label: strings.get('traceroute'),
                  ),
                  _buildNavItem(
                    index: 2,
                    icon: Icons.speed_rounded,
                    label: strings.get('bandwidth'),
                  ),
                  _buildNavItem(
                    index: 3,
                    icon: Icons.bolt_rounded,
                    label: strings.get('warp'),
                  ),
                  _buildNavItem(
                    index: 4,
                    icon: Icons.radar,
                    label: strings.get('portScanner'),
                  ),
                  _buildNavItem(
                    index: 5,
                    icon: Icons.dns,
                    label: strings.get('dnsLookup'),
                  ),
                  _buildNavItem(
                    index: 6,
                    icon: Icons.route,
                    label: strings.get('mtr'),
                  ),
                  _buildNavItem(
                    index: 7,
                    icon: Icons.settings_rounded,
                    label: strings.get('settings'),
                  ),
                  const Spacer(),
                  Divider(color: context.borderColor, height: 1),
                  // Engine Status Footer
                  AnimatedBuilder(
                    animation: _pingController,
                    builder: (context, _) {
                      final bool isNative = _pingController.isNativeEngineActive;
                      return Container(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: isNative ? AppColors.latencyFast : AppColors.latencyModerate,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isNative
                                        ? strings.get('engineNative')
                                        : strings.get('engineFallback'),
                                    style: TextStyle(
                                      color: isNative ? AppColors.latencyFast : AppColors.latencyModerate,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              platformLabel,
                              style: TextStyle(
                                color: context.textMutedColor,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            // Main Body — IndexedStack keeps state alive across tab switches.
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  PingMatrixScreen(controller: _pingController),
                  const TracerouteScreen(),
                  const BandwidthScreen(),
                  WarpScreen(
                    controller: _warpController,
                    onAddToPingMatrix: _addWarpEndpointsToMatrix,
                  ),
                  const PortscanScreen(),
                  const DnslookupScreen(),
                  const MtrScreen(),
                  SettingsScreen(
                      settings: widget.settings, webhooks: _webhooks),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required String label,
    String? badge,
  }) {
    final bool isSelected = _selectedIndex == index;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: InkWell(
        onTap: () => setState(() => _selectedIndex = index),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary.withValues(alpha: 0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? AppColors.primary.withValues(alpha: 0.4) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected ? AppColors.primary : context.textSecondaryColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    color: isSelected ? context.textPrimaryColor : context.textSecondaryColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isSelected ? AppColors.primary : context.bgColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? Colors.white : context.textMutedColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

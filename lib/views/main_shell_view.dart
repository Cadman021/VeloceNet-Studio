import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import '../core/i18n/app_strings.dart';
import '../core/theme/theme_x.dart';
import '../core/settings/settings_controller.dart';
import '../core/theme/app_colors.dart';
import '../models/ping_target.dart';
import '../state/ping_matrix_controller.dart';
import 'bandwidth/bandwidth_screen.dart';
import 'ping_matrix/ping_matrix_screen.dart';
import 'portscan/portscan_screen.dart';
import 'settings/settings_screen.dart';
import 'traceroute/traceroute_screen.dart';
import 'warp/warp_controller.dart';
import 'warp/warp_screen.dart';

class MainShellView extends StatefulWidget {
  final SettingsController settings;
  const MainShellView({super.key, required this.settings});

  @override
  State<MainShellView> createState() => _MainShellViewState();
}

class _MainShellViewState extends State<MainShellView> {
  int _selectedIndex = 0;
  late final PingMatrixController _pingController;
  late final WarpController _warpController;

  @override
  void initState() {
    super.initState();
    _pingController = PingMatrixController();
    _pingController.init();
    _warpController = WarpController();
  }

  @override
  void dispose() {
    _pingController.dispose();
    _warpController.dispose();
    super.dispose();
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
    final platformLabel = Platform.isWindows
        ? 'Windows x64 Native Core'
        : Platform.isLinux
            ? 'Linux Native Core'
            : Platform.isMacOS
                ? 'macOS Native Core'
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
                  SettingsScreen(settings: widget.settings),
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

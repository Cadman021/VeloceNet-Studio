import 'package:flutter/material.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_x.dart';
import '../../models/ping_metric.dart';
import '../../state/ping_matrix_controller.dart';
import 'widgets/add_target_dialog.dart';
import 'widgets/stats_summary_bar.dart';
import 'widgets/target_card.dart';

class PingMatrixScreen extends StatefulWidget {
  final PingMatrixController controller;

  const PingMatrixScreen({super.key, required this.controller});

  @override
  State<PingMatrixScreen> createState() => _PingMatrixScreenState();
}

class _PingMatrixScreenState extends State<PingMatrixScreen> {
  String _searchQuery = '';
  String _statusFilter = 'ALL'; // ALL, ONLINE, DEGRADED, OFFLINE

  void _openAddDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AddTargetDialog(
        onAdd: (newTarget) {
          widget.controller.addTarget(newTarget);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final targets = widget.controller.targets;
        final metrics = widget.controller.metrics;

        // Apply search & status filter
        final filteredTargets = targets.where((t) {
          final m = metrics[t.id];
          final matchesSearch = t.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              t.host.toLowerCase().contains(_searchQuery.toLowerCase());

          if (!matchesSearch) return false;

          if (_statusFilter == 'ONLINE') {
            return m?.status == TargetStatus.online;
          } else if (_statusFilter == 'DEGRADED') {
            return m?.status == TargetStatus.degraded;
          } else if (_statusFilter == 'OFFLINE') {
            return m?.status == TargetStatus.offline;
          }
          return true;
        }).toList();

        return Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Stats Summary Bar
                StatsSummaryBar(
                  controller: widget.controller,
                  onAddTargetPressed: _openAddDialog,
                ),
                const SizedBox(height: 16),
                // Filter & Search Row
                Row(
                  children: [
                    // Search box
                    Expanded(
                      flex: 2,
                      child: Container(
                        height: 38,
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: TextField(
                          onChanged: (val) => setState(() => _searchQuery = val),
                          style: TextStyle(color: context.textPrimaryColor, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: strings.get('searchHint'),
                            hintStyle: TextStyle(color: context.textMutedColor, fontSize: 12),
                            prefixIcon: Icon(Icons.search, size: 16, color: context.textMutedColor),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(vertical: 9),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Status Filter chips
                    _buildFilterChip(strings.get('filterAll'), 'ALL', null),
                    const SizedBox(width: 6),
                    _buildFilterChip(strings.get('filterOnline'), 'ONLINE', AppColors.latencyFast),
                    const SizedBox(width: 6),
                    _buildFilterChip(strings.get('filterDegraded'), 'DEGRADED', AppColors.latencyModerate),
                    const SizedBox(width: 6),
                    _buildFilterChip(strings.get('filterOffline'), 'OFFLINE', AppColors.latencyCritical),
                  ],
                ),
                const SizedBox(height: 16),
                // Target Cards Grid
                Expanded(
                  child: filteredTargets.isEmpty
                      ? _buildEmptyState()
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            int crossAxisCount = 3;
                            if (constraints.maxWidth < 700) {
                              crossAxisCount = 1;
                            } else if (constraints.maxWidth < 1150) {
                              crossAxisCount = 2;
                            } else if (constraints.maxWidth > 1600) {
                              crossAxisCount = 4;
                            }

                            return GridView.builder(
                              physics: const BouncingScrollPhysics(),
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                crossAxisSpacing: 14,
                                mainAxisSpacing: 14,
                                mainAxisExtent: 220,
                              ),
                              itemCount: filteredTargets.length,
                              itemBuilder: (context, index) {
                                final target = filteredTargets[index];
                                final metric = metrics[target.id];

                                return TargetCard(
                                  target: target,
                                  metric: metric,
                                  onDeletePressed: () {
                                    widget.controller.removeTarget(target.id);
                                  },
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFilterChip(String label, String value, Color? dotColor) {
    final bool isSelected = _statusFilter == value;

    return InkWell(
      onTap: () => setState(() => _statusFilter = value),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primary.withValues(alpha: 0.18) : context.surfaceColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? AppColors.primary : context.borderColor,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? AppColors.primary : context.textSecondaryColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final strings = AppStrings.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, size: 48, color: context.textMutedColor.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text(
            strings.get('emptyFilter'),
            style: TextStyle(color: context.textSecondaryColor, fontSize: 14),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _openAddDialog,
            icon: const Icon(Icons.add, size: 16),
            label: Text(strings.get('addNewServer')),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

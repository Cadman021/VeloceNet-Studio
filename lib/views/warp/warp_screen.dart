import 'package:flutter/material.dart';
import '../../core/theme/theme_x.dart';
import 'warp_controller.dart';
import 'widgets/warp_config_card.dart';
import 'widgets/warp_header_card.dart';
import 'widgets/warp_progress_card.dart';
import 'widgets/warp_results_card.dart';

class WarpScreen extends StatefulWidget {
  final WarpController controller;
  final void Function(List<Map<String, dynamic>> endpoints)? onAddToPingMatrix;

  const WarpScreen({
    super.key,
    required this.controller,
    this.onAddToPingMatrix,
  });

  @override
  State<WarpScreen> createState() => _WarpScreenState();
}

class _WarpScreenState extends State<WarpScreen> {
  final TextEditingController _parallelController =
      TextEditingController(text: '32');
  final TextEditingController _timeoutController =
      TextEditingController(text: '1200');
  final TextEditingController _topNController =
      TextEditingController(text: '5');

  @override
  void dispose() {
    _parallelController.dispose();
    _timeoutController.dispose();
    _topNController.dispose();
    super.dispose();
  }

  void _applyNumeric() {
    final p = int.tryParse(_parallelController.text.trim());
    final t = int.tryParse(_timeoutController.text.trim());
    if (p != null) widget.controller.setParallel(p);
    if (t != null) widget.controller.setTimeoutMs(t);
    _parallelController.text = '${widget.controller.parallel}';
    _timeoutController.text = '${widget.controller.timeoutMs}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final prog = c.progress;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WarpHeaderCard(controller: c),
                const SizedBox(height: 12),
                WarpConfigCard(
                  controller: c,
                  parallelController: _parallelController,
                  timeoutController: _timeoutController,
                  onApply: _applyNumeric,
                ),
                const SizedBox(height: 12),
                WarpProgressCard(progress: prog),
                const SizedBox(height: 12),
                WarpResultsCard(
                  controller: c,
                  results: prog.results,
                  topNController: _topNController,
                  onApplyNumeric: _applyNumeric,
                  onAddToPingMatrix: widget.onAddToPingMatrix,
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

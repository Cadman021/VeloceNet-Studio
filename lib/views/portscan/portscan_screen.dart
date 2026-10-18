import 'package:flutter/material.dart';
import '../../core/theme/theme_x.dart';
import 'portscan_controller.dart';
import 'widgets/portscan_config_card.dart';
import 'widgets/portscan_header_card.dart';
import 'widgets/portscan_results_card.dart';

class PortscanScreen extends StatefulWidget {
  const PortscanScreen({super.key});

  @override
  State<PortscanScreen> createState() => _PortscanScreenState();
}

class _PortscanScreenState extends State<PortscanScreen> {
  late final PortscanController _controller;
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portsController =
      TextEditingController(text: '21-25,53,80,110,143,443,445,3389,8080,8443');
  final TextEditingController _timeoutController =
      TextEditingController(text: '1000');
  final TextEditingController _concurrencyController =
      TextEditingController(text: '64');

  @override
  void initState() {
    super.initState();
    _controller = PortscanController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portsController.dispose();
    _timeoutController.dispose();
    _concurrencyController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    final timeout = int.tryParse(_timeoutController.text.trim());
    final concurrency = int.tryParse(_concurrencyController.text.trim());
    if (timeout != null) {
      _timeoutController.text = '${timeout.clamp(100, 5000)}';
    }
    if (concurrency != null) {
      _concurrencyController.text = '${concurrency.clamp(1, 256)}';
    }
    _controller.start(
      _hostController.text,
      _portsController.text,
      timeoutMs: timeout ?? 1000,
      concurrency: concurrency ?? 64,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PortscanHeaderCard(controller: _controller, onStart: _start),
                const SizedBox(height: 12),
                PortscanConfigCard(
                  controller: _controller,
                  hostController: _hostController,
                  portsController: _portsController,
                  timeoutController: _timeoutController,
                  concurrencyController: _concurrencyController,
                  onStart: _start,
                ),
                const SizedBox(height: 12),
                PortscanResultsCard(controller: _controller),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

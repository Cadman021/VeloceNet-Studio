import 'dart:io';

import 'package:flutter/material.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/theme_x.dart';
import '../../services/dns_client.dart';
import 'dnslookup_controller.dart';
import 'widgets/dns_config_card.dart';
import 'widgets/dns_header_card.dart';
import 'widgets/dns_results_card.dart';

class DnslookupScreen extends StatefulWidget {
  const DnslookupScreen({super.key});

  @override
  State<DnslookupScreen> createState() => _DnslookupScreenState();
}

class _DnslookupScreenState extends State<DnslookupScreen> {
  late final DnslookupController _controller;
  final TextEditingController _hostController =
      TextEditingController(text: 'example.com');
  final TextEditingController _customServerController = TextEditingController();
  final TextEditingController _timeoutController =
      TextEditingController(text: '2000');
  DnsQueryType _qtype = DnsQueryType.a;
  String _serverKey = 'Cloudflare';

  @override
  void initState() {
    super.initState();
    _controller = DnslookupController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _customServerController.dispose();
    _timeoutController.dispose();
    _controller.dispose();
    super.dispose();
  }

  String get _effectiveServer {
    if (_serverKey == '__custom__') return _customServerController.text.trim();
    return kDnsServers[_serverKey] ?? '1.1.1.1';
  }

  void _run() {
    final timeout = int.tryParse(_timeoutController.text.trim());
    final server = _effectiveServer;
    if (_serverKey == '__custom__' && !_isValidServerIp(server, context)) {
      return;
    }
    _controller.query(
      rawHost: _hostController.text,
      qtype: _qtype,
      serverIp: server,
      timeoutMs: timeout ?? 2000,
    );
  }

  bool _isValidServerIp(String ip, BuildContext context) {
    final ok = InternetAddress.tryParse(ip.trim()) != null;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).get('invalidServer')),
        ),
      );
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DnsHeaderCard(controller: c, onRun: _run),
                const SizedBox(height: 12),
                DnsConfigCard(
                  controller: c,
                  hostController: _hostController,
                  customServerController: _customServerController,
                  timeoutController: _timeoutController,
                  qtype: _qtype,
                  serverKey: _serverKey,
                  onQtypeChanged: (t) => setState(() => _qtype = t),
                  onServerChanged: (key) => setState(() => _serverKey = key),
                  onRun: _run,
                ),
                const SizedBox(height: 12),
                DnsResultsCard(
                  records: c.records,
                  response: c.response,
                  isRunning: c.isRunning,
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

import 'package:flutter/material.dart';
import '../../../core/i18n/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_x.dart';
import '../../../models/ping_target.dart';
import '../../traceroute/traceroute_controller.dart';

class AddTargetDialog extends StatefulWidget {
  final Function(PingTarget) onAdd;

  const AddTargetDialog({super.key, required this.onAdd});

  @override
  State<AddTargetDialog> createState() => _AddTargetDialogState();
}

class _AddTargetDialogState extends State<AddTargetDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '80');
  final _intervalController = TextEditingController(text: '1000');
  final _timeoutController = TextEditingController(text: '1500');

  NetworkProtocol _selectedProtocol = NetworkProtocol.icmp;

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _intervalController.dispose();
    _timeoutController.dispose();
    super.dispose();
  }

  void _applyPreset(String name, String host, int port, NetworkProtocol proto) {
    setState(() {
      _nameController.text = name;
      _hostController.text = host;
      _portController.text = port.toString();
      _selectedProtocol = proto;
    });
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      // Full millisecond timestamp (not ~/1000 seconds): two adds can no
      // longer collide by landing in the same second and clobbering each
      // other's metrics. The dialog also pops on submit, so same-ms
      // double-submit is impossible through this UI.
      final id = DateTime.now().millisecondsSinceEpoch;
      final host =
          TracerouteController.normalizeTraceHost(_hostController.text) ??
              _hostController.text.trim();
      var name = _nameController.text.trim();
      if (name.isEmpty) name = host;
      final target = PingTarget(
        id: id,
        name: name,
        host: host,
        port: int.tryParse(_portController.text.trim()) ?? 80,
        protocol: _selectedProtocol,
        intervalMs: int.tryParse(_intervalController.text.trim()) ?? 1000,
        timeoutMs: int.tryParse(_timeoutController.text.trim()) ?? 1500,
      );

      widget.onAdd(target);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Dialog(
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.add_circle_outline, color: AppColors.primary, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    strings.get('addServerTitle'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimaryColor,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, size: 18, color: context.textMutedColor),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Presets
              Text(
                strings.get('quickPresets'),
                style: TextStyle(color: context.textMutedColor, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildPresetChip('Cloudflare DNS (1.1.1.1)', '1.1.1.1', 53, NetworkProtocol.icmp),
                  _buildPresetChip('Google DNS (8.8.8.8)', '8.8.8.8', 53, NetworkProtocol.icmp),
                  _buildPresetChip('Quad9 (9.9.9.9)', '9.9.9.9', 53, NetworkProtocol.icmp),
                  _buildPresetChip('AWS EU (TCP:443)', 'ec2.eu-central-1.amazonaws.com', 443, NetworkProtocol.tcp),
                  _buildPresetChip('GitHub (TCP:443)', 'github.com', 443, NetworkProtocol.tcp),
                ],
              ),
              const SizedBox(height: 18),
              Divider(color: context.borderColor, height: 1),
              const SizedBox(height: 18),
              // Name and Host
              Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: _buildTextField(
                      context,
                      controller: _nameController,
                      label: strings.get('serverName'),
                      hint: strings.get('serverNameHint'),
                      validator: (v) => v == null || v.isEmpty ? strings.get('serverNameRequired') : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: _buildTextField(
                      context,
                      controller: _hostController,
                      label: strings.get('hostLabel'),
                      hint: strings.get('hostHint'),
                      validator: (v) {
                        if (v == null || v.isEmpty) return strings.get('hostRequired');
                        // Same validator the engines use: "https://github.com"
                        // normalizes to "github.com" on submit, while
                        // genuinely bad hosts fail here instead of becoming
                        // a stuck Pending card later.
                        if (TracerouteController.normalizeTraceHost(v) == null) {
                          return strings.get('invalidHost');
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // Protocol and Port
              Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.get('probeProtocol'),
                          style: TextStyle(color: context.textSecondaryColor, fontSize: 12),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: context.bgColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: context.borderColor),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<NetworkProtocol>(
                              value: _selectedProtocol,
                              isExpanded: true,
                              dropdownColor: context.surfaceColor,
                              items: NetworkProtocol.values.map((p) {
                                return DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    p.label,
                                    style: TextStyle(color: context.textPrimaryColor, fontSize: 13),
                                  ),
                                );
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _selectedProtocol = val);
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: _buildTextField(
                      context,
                      controller: _portController,
                      label: strings.get('portTcp'),
                      hint: '80',
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final p = int.tryParse((v ?? '').trim());
                        if (p == null || p < 1 || p > 65535) return '1-65535';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: _buildTextField(
                      context,
                      controller: _intervalController,
                      label: strings.get('intervalMs'),
                      hint: '1000',
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim());
                        if (n == null || n < 200 || n > 60000) return '200-60000';
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(strings.get('cancel'), style: TextStyle(color: context.textMutedColor)),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(strings.get('addToMatrix')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPresetChip(String label, String host, int port, NetworkProtocol proto) {
    // Use full label as display name (previous split(' ')[0] truncated names).
    return ActionChip(
      label: Text(label, style: TextStyle(fontSize: 11, color: context.textSecondaryColor)),
      backgroundColor: context.bgColor,
      side: BorderSide(color: context.borderColor),
      onPressed: () => _applyPreset(label, host, port, proto),
    );
  }

  Widget _buildTextField(
    BuildContext context, {
    required TextEditingController controller,
    required String label,
    required String hint,
    String? Function(String?)? validator,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: context.textSecondaryColor, fontSize: 12)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          validator: validator,
          keyboardType: keyboardType,
          style: TextStyle(color: context.textPrimaryColor, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: context.textMutedColor, fontSize: 12),
            filled: true,
            fillColor: context.bgColor,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.primary),
            ),
          ),
        ),
      ],
    );
  }
}

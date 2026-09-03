import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sip_preset.dart';
import '../../radio/providers.dart';
import '../../theme/control_room_theme.dart';

/// Editor for the radio line (SIP/EBU 3326) preset.
class SipPresetEditorScreen extends ConsumerStatefulWidget {
  const SipPresetEditorScreen({super.key});

  @override
  ConsumerState<SipPresetEditorScreen> createState() =>
      _SipPresetEditorScreenState();
}

class _SipPresetEditorScreenState
    extends ConsumerState<SipPresetEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late Future<SipPreset> _load;
  late SipPreset _preset;

  static const _codecLabels = {
    'g722': 'G.722 (EBU 3326)',
    'opus': 'Opus',
    'pcmu': 'G.711 µ-law',
    'pcma': 'G.711 A-law',
  };

  @override
  void initState() {
    super.initState();
    _load = ref.read(sipPresetProvider.future);
    _preset = const SipPreset();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio line'),
        actions: [
          TextButton(
            onPressed: () {
              if (!(_formKey.currentState?.validate() ?? false)) return;
              _formKey.currentState?.save();
              if (!_preset.isConfigured) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Enter registrar, username and extension first',
                    ),
                  ),
                );
                return;
              }
              // A saved line is meant to be usable: keep it enabled so the
              // manual Connect button registers regardless.
              ref
                  .read(sipPresetProvider.notifier)
                  .save(_preset.copyWith(enabled: true));
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
      body: FutureBuilder<SipPreset>(
        future: _load,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          _preset = snap.data!;
          return _buildForm();
        },
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Radio line enabled'),
            subtitle: Text(
              _preset.isConfigured
                  ? _preset.displayTarget
                  : 'Fill the details below to enable',
              style: const TextStyle(color: ControlRoomColors.textSecondary),
            ),
            value: _preset.enabled,
            onChanged: (v) => setState(() => _preset = _preset.copyWith(enabled: v)),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: _preset.name,
            decoration: const InputDecoration(labelText: 'Line name'),
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
            onSaved: (v) => _preset = _preset.copyWith(name: v),
          ),
          TextFormField(
            initialValue: _preset.registrarHost,
            decoration: const InputDecoration(
              labelText: 'Registrar / server',
              hintText: 'e.g. 158.220.126.145',
            ),
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
            onSaved: (v) => _preset = _preset.copyWith(registrarHost: v),
          ),
          TextFormField(
            initialValue: '${_preset.registrarPort}',
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
            validator: (v) =>
                int.tryParse(v ?? '') == null ? 'Invalid port' : null,
            onSaved: (v) =>
                _preset = _preset.copyWith(registrarPort: int.parse(v!)),
          ),
          TextFormField(
            initialValue: _preset.username,
            decoration: const InputDecoration(
              labelText: 'SIP username',
              hintText: 'e.g. field',
            ),
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
            onSaved: (v) => _preset = _preset.copyWith(username: v),
          ),
          TextFormField(
            initialValue: _preset.password,
            decoration: const InputDecoration(labelText: 'SIP password'),
            obscureText: true,
            onSaved: (v) => _preset = _preset.copyWith(password: v),
          ),
          TextFormField(
            initialValue: _preset.extension,
            decoration: const InputDecoration(
              labelText: 'Extension / AOR',
              hintText: 'e.g. field',
            ),
            onSaved: (v) => _preset = _preset.copyWith(extension: v),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _preset.codec,
            decoration: const InputDecoration(labelText: 'Preferred codec'),
            items: _codecLabels.entries
                .map(
                  (e) => DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value),
                  ),
                )
                .toList(),
            onChanged: (v) {},
            onSaved: (v) => _preset = _preset.copyWith(codec: v ?? 'g722'),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto-answer studio calls'),
            subtitle: const Text(
              'Answer incoming calls without tapping Accept',
              style: TextStyle(color: ControlRoomColors.textSecondary),
            ),
            value: _preset.autoAnswer,
            onChanged: (v) =>
                setState(() => _preset = _preset.copyWith(autoAnswer: v)),
          ),
          const SizedBox(height: 20),
          const Text(
            'EBU 3326 contribution over SIP. The studio console calls this '
            'device; audio is relayed by the registrar, so it works behind '
            'symmetric NAT.',
            style: TextStyle(color: ControlRoomColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../broadcast/providers.dart';
import '../models/camera_settings.dart';
import '../models/destination_preset.dart';
import '../models/encoder_settings.dart';
import '../models/return_feed_config.dart';
import '../services/auth_service.dart';
import '../services/broadcast_reporter.dart';
import '../theme/control_room_theme.dart';
import 'widgets/camera_controls.dart';

export '../models/return_feed_config.dart' show SrtSenderMode;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets =
        ref.watch(presetsProvider).value ?? const <DestinationPreset>[];
    final encoder =
        ref.watch(encoderSettingsProvider).value ?? const EncoderSettings();
    final camera =
        ref.watch(cameraSettingsProvider).value ?? const CameraSettings();
    final returnFeed =
        ref.watch(returnFeedConfigProvider).value ?? const ReturnFeedConfig();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader('Destinations'),
          for (final preset in presets)
            Card(
              color: ControlRoomColors.surface,
              child: ListTile(
                title: Text(preset.name),
                subtitle: Text(
                  '${preset.protocol.name.toUpperCase()} · ${preset.displayTarget}',
                  style: const TextStyle(
                    color: ControlRoomColors.textSecondary,
                  ),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      ref.read(presetsProvider.notifier).remove(preset.id),
                ),
                onTap: () => _editPreset(context, ref, preset),
              ),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add destination'),
            onPressed: () => _editPreset(
              context,
              ref,
              DestinationPreset(
                id: DateTime.now().microsecondsSinceEpoch.toString(),
                name: 'Station',
              ),
            ),
          ),
          const SizedBox(height: 24),
          _sectionHeader('Encoder'),
          _EncoderSection(encoder: encoder),
          const SizedBox(height: 24),
          _sectionHeader('Camera'),
          CameraControlsSection(camera: camera),
          const SizedBox(height: 24),
          _sectionHeader('Audio'),
          _AudioInputSection(),
          const SizedBox(height: 24),
          _sectionHeader('Return feed'),
          _ReturnFeedSection(config: returnFeed),
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: () async {
                await ref.read(authServiceProvider).signOut();
              },
              icon: const Icon(Icons.logout, color: Colors.white38, size: 18),
              label: const Text(
                'Sign out',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: ControlRoomColors.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    ),
  );

  Future<void> _editPreset(
    BuildContext context,
    WidgetRef ref,
    DestinationPreset preset,
  ) async {
    final saved = await Navigator.of(context).push<DestinationPreset>(
      MaterialPageRoute(builder: (_) => PresetEditorScreen(preset: preset)),
    );
    if (saved != null) {
      await ref.read(presetsProvider.notifier).upsert(saved);
    }
  }
}

class PresetEditorScreen extends StatefulWidget {
  const PresetEditorScreen({super.key, required this.preset});

  final DestinationPreset preset;

  @override
  State<PresetEditorScreen> createState() => _PresetEditorScreenState();
}

class _PresetEditorScreenState extends State<PresetEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late var _preset = widget.preset;

  @override
  Widget build(BuildContext context) {
    final isSrt = _preset.protocol == BroadcastProtocol.srt;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Destination'),
        actions: [
          TextButton(
            onPressed: () {
              if (_formKey.currentState?.validate() ?? false) {
                _formKey.currentState?.save();
                Navigator.of(context).pop(_preset);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              initialValue: _preset.name,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              onSaved: (v) => _preset = _preset.copyWith(name: v),
            ),
            const SizedBox(height: 12),
            SegmentedButton<BroadcastProtocol>(
              segments: const [
                ButtonSegment(value: BroadcastProtocol.srt, label: Text('SRT')),
                ButtonSegment(
                  value: BroadcastProtocol.rtmp,
                  label: Text('RTMP'),
                ),
              ],
              selected: {_preset.protocol},
              onSelectionChanged: (selection) => setState(
                () => _preset = _preset.copyWith(protocol: selection.first),
              ),
            ),
            const SizedBox(height: 12),
            if (isSrt) _srtFields() else _rtmpFields(),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _srtFields() {
    return Column(
      children: [
        TextFormField(
          initialValue: _preset.host,
          decoration: const InputDecoration(
            labelText: 'Host',
            hintText: 'e.g. ingest.station.tv or 10.0.0.5',
          ),
          validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          onSaved: (v) => _preset = _preset.copyWith(host: v),
        ),
        TextFormField(
          initialValue: '${_preset.port}',
          decoration: const InputDecoration(labelText: 'Port'),
          keyboardType: TextInputType.number,
          validator: (v) =>
              int.tryParse(v ?? '') == null ? 'Invalid port' : null,
          onSaved: (v) => _preset = _preset.copyWith(port: int.parse(v!)),
        ),
        TextFormField(
          initialValue: _preset.streamId,
          decoration: const InputDecoration(
            labelText: 'Stream ID (optional)',
            hintText: 'e.g. publish:cam1',
          ),
          onSaved: (v) => _preset = _preset.copyWith(streamId: v),
        ),
        TextFormField(
          initialValue: _preset.passphrase,
          decoration: const InputDecoration(labelText: 'Passphrase (optional)'),
          obscureText: true,
          onSaved: (v) => _preset = _preset.copyWith(passphrase: v),
        ),
        TextFormField(
          initialValue: '${_preset.latencyMs}',
          decoration: const InputDecoration(
            labelText: 'SRT latency (ms)',
            helperText: 'Higher survives worse networks; 200 is a good default',
          ),
          keyboardType: TextInputType.number,
          validator: (v) => int.tryParse(v ?? '') == null ? 'Invalid' : null,
          onSaved: (v) => _preset = _preset.copyWith(latencyMs: int.parse(v!)),
        ),
      ],
    );
  }

  Widget _rtmpFields() {
    return Column(
      children: [
        TextFormField(
          initialValue: _preset.rtmpUrl,
          decoration: const InputDecoration(
            labelText: 'RTMP URL',
            hintText: 'rtmp://ingest.station.tv/live',
          ),
          validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          onSaved: (v) => _preset = _preset.copyWith(rtmpUrl: v),
        ),
        TextFormField(
          initialValue: _preset.streamKey,
          decoration: const InputDecoration(labelText: 'Stream key'),
          obscureText: true,
          onSaved: (v) => _preset = _preset.copyWith(streamKey: v),
        ),
      ],
    );
  }
}

class _AudioInputSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AudioInputSection> createState() => _AudioInputSectionState();
}

class _AudioInputSectionState extends ConsumerState<_AudioInputSection> {
  List<BroadcastAudioDevice>? _devices;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    final ctrl = ref.read(broadcastControllerProvider.notifier);
    final devices = await ctrl.getAudioDevices();
    if (mounted) {
      setState(() {
        _devices = devices;
        // Auto-select external mic if available (USB or wired)
        final external = devices.cast<BroadcastAudioDevice?>().firstWhere(
          (d) => d!.type == 'usb' || d.type == 'wired' || d.type == 'bluetooth',
          orElse: () => null,
        );
        if (external != null) {
          _selectedId = external.id;
          ctrl.selectAudioDevice(external.id);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: ControlRoomColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Microphone',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (_devices == null)
              const Text(
                'Loading...',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              )
            else if (_devices!.isEmpty)
              const Text(
                'No external mics detected',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              )
            else
              for (final d in _devices!)
                ListTile(
                  title: Text(d.name, style: const TextStyle(fontSize: 12)),
                  subtitle: Text(
                    d.type,
                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                  leading: Icon(
                    _selectedId == d.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: ControlRoomColors.amber,
                  ),
                  dense: true,
                  onTap: () {
                    setState(() => _selectedId = d.id);
                    ref
                        .read(broadcastControllerProvider.notifier)
                        .selectAudioDevice(d.id);
                  },
                ),
            const SizedBox(height: 4),
            Text(
              'Auto uses the system default mic. Select a specific device to use an external mic.',
              style: TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}

class _EncoderSection extends ConsumerWidget {
  const _EncoderSection({required this.encoder});

  final EncoderSettings encoder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(encoderSettingsProvider.notifier);
    return Card(
      color: ControlRoomColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(
              'Resolution',
              DropdownButton<ResolutionPreset>(
                value: encoder.resolution,
                items: [
                  for (final r in ResolutionPreset.values)
                    DropdownMenuItem(value: r, child: Text(r.label)),
                ],
                onChanged: (r) => r == null
                    ? null
                    : notifier.save(encoder.copyWith(resolution: r)),
              ),
            ),
            _row(
              'Frame rate',
              DropdownButton<int>(
                value: encoder.fps,
                items: const [
                  DropdownMenuItem(value: 25, child: Text('25')),
                  DropdownMenuItem(value: 30, child: Text('30')),
                  DropdownMenuItem(value: 50, child: Text('50')),
                  DropdownMenuItem(value: 60, child: Text('60')),
                ],
                onChanged: (fps) => fps == null
                    ? null
                    : notifier.save(encoder.copyWith(fps: fps)),
              ),
            ),
            _row(
              'Codec',
              DropdownButton<BroadcastVideoCodec>(
                value: encoder.codec,
                items: const [
                  DropdownMenuItem(
                    value: BroadcastVideoCodec.h264,
                    child: Text('H.264'),
                  ),
                  DropdownMenuItem(
                    value: BroadcastVideoCodec.hevc,
                    child: Text('HEVC'),
                  ),
                ],
                onChanged: (codec) => codec == null
                    ? null
                    : notifier.save(encoder.copyWith(codec: codec)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Video bitrate: ${(encoder.videoBitrateBps / 1_000_000).toStringAsFixed(1)} Mb/s',
              style: const TextStyle(fontSize: 13),
            ),
            Slider(
              value: encoder.videoBitrateBps.toDouble(),
              min: 500000,
              max: 12000000,
              divisions: 23,
              onChanged: (v) =>
                  notifier.save(encoder.copyWith(videoBitrateBps: v.round())),
            ),
            const SizedBox(height: 8),
            _row(
              'Mirror front camera',
              Switch(
                value: encoder.mirrorFrontCamera,
                onChanged: (v) =>
                    notifier.save(encoder.copyWith(mirrorFrontCamera: v)),
              ),
            ),
            const Text(
              'Encoder changes apply on next app start or after re-initializing the camera.',
              style: TextStyle(
                fontSize: 11,
                color: ControlRoomColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, Widget control) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [Text(label), control],
  );
}

class _ReturnFeedSection extends ConsumerWidget {
  const _ReturnFeedSection({required this.config});

  final ReturnFeedConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(returnFeedConfigProvider.notifier);
    return Card(
      color: ControlRoomColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              initialValue: config.url,
              decoration: const InputDecoration(
                labelText: 'Return feed URL',
                hintText: 'srt://salttelevision.com:8011',
              ),
              onChanged: (v) => notifier.save(config.copyWith(url: v)),
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: '${config.latencyMs}',
              decoration: const InputDecoration(
                labelText: 'Latency / buffer (ms)',
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) {
                final ms = int.tryParse(v);
                if (ms != null) notifier.save(config.copyWith(latencyMs: ms));
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: config.srtPassphrase,
              decoration: const InputDecoration(
                labelText: 'SRT Passphrase (optional)',
              ),
              obscureText: true,
              onChanged: (v) =>
                  notifier.save(config.copyWith(srtPassphrase: v)),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('SRT Sender Mode'),
                DropdownButton<SrtSenderMode>(
                  value: config.srtSenderMode,
                  items: const [
                    DropdownMenuItem(
                      value: SrtSenderMode.caller,
                      child: Text('Caller'),
                    ),
                    DropdownMenuItem(
                      value: SrtSenderMode.listener,
                      child: Text('Listener'),
                    ),
                    DropdownMenuItem(
                      value: SrtSenderMode.rendezvous,
                      child: Text('Rendezvous'),
                    ),
                  ],
                  onChanged: (m) => m == null
                      ? null
                      : notifier.save(config.copyWith(srtSenderMode: m)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Player backend'),
                DropdownButton<ReturnFeedBackend>(
                  value: config.backend,
                  items: const [
                    DropdownMenuItem(
                      value: ReturnFeedBackend.auto,
                      child: Text('Auto'),
                    ),
                    DropdownMenuItem(
                      value: ReturnFeedBackend.mediaKit,
                      child: Text('media_kit'),
                    ),
                  ],
                  onChanged: (b) => b == null
                      ? null
                      : notifier.save(config.copyWith(backend: b)),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show automatically when going live'),
              value: config.autoplayOnLive,
              onChanged: (v) =>
                  notifier.save(config.copyWith(autoplayOnLive: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Start muted (echo protection)'),
              value: config.startMuted,
              onChanged: (v) => notifier.save(config.copyWith(startMuted: v)),
            ),
            const Divider(height: 24),
            const Text(
              'BROADCASTER',
              style: TextStyle(
                color: ControlRoomColors.amber,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: config.broadcasterId,
              decoration: const InputDecoration(
                labelText: 'Broadcaster ID',
                hintText: 'e.g. presenter-1-mbale',
              ),
              onChanged: (v) {
                notifier.save(config.copyWith(broadcasterId: v));
                if (v.isNotEmpty) {
                  ref
                      .read(broadcastReporterProvider)
                      .register(v, config.broadcasterName);
                }
              },
            ),
            TextFormField(
              initialValue: config.broadcasterName,
              decoration: const InputDecoration(
                labelText: 'Display name',
                hintText: 'e.g. Field Presenter 1 (Mbale)',
              ),
              onChanged: (v) {
                notifier.save(config.copyWith(broadcasterName: v));
                if (config.broadcasterId.isNotEmpty) {
                  ref
                      .read(broadcastReporterProvider)
                      .register(config.broadcasterId, v);
                }
              },
            ),
            const Divider(height: 24),
            const Text(
              'TALKBACK',
              style: TextStyle(
                color: ControlRoomColors.amber,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable talkback (audio intercom)'),
              value: config.talkbackEnabled,
              onChanged: (v) =>
                  notifier.save(config.copyWith(talkbackEnabled: v)),
            ),
            TextFormField(
              initialValue: config.talkbackUrl,
              decoration: const InputDecoration(
                labelText: 'Talkback SRT URL',
                hintText: 'srt://talkback.server.com:port',
              ),
              enabled: config.talkbackEnabled,
              onChanged: (v) => notifier.save(config.copyWith(talkbackUrl: v)),
            ),
            TextFormField(
              initialValue: '${config.talkbackLatencyMs}',
              decoration: const InputDecoration(
                labelText: 'Talkback latency (ms)',
              ),
              keyboardType: TextInputType.number,
              enabled: config.talkbackEnabled,
              onChanged: (v) {
                final ms = int.tryParse(v);
                if (ms != null)
                  notifier.save(config.copyWith(talkbackLatencyMs: ms));
              },
            ),
            TextFormField(
              initialValue: config.talkbackPassphrase,
              decoration: const InputDecoration(
                labelText: 'Talkback SRT Passphrase (optional)',
              ),
              obscureText: true,
              enabled: config.talkbackEnabled,
              onChanged: (v) =>
                  notifier.save(config.copyWith(talkbackPassphrase: v)),
            ),
          ],
        ),
      ),
    );
  }
}

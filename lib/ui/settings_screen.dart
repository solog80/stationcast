import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../broadcast/providers.dart';
import '../models/camera_settings.dart';
import '../models/destination_preset.dart';
import '../models/encoder_settings.dart';
import '../models/recording_settings.dart';
import '../models/return_feed_config.dart';
import '../models/sip_preset.dart';
import '../radio/providers.dart';
import '../services/auth_service.dart';
import '../services/broadcast_reporter.dart';
import '../theme/control_room_theme.dart';
import 'widgets/camera_controls.dart';
import 'widgets/sip_preset_editor.dart';

export '../models/return_feed_config.dart' show SrtSenderMode;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets =
        ref.watch(presetsProvider).value ?? const <DestinationPreset>[];
    final encoder =
        ref.watch(encoderSettingsProvider).value ?? const EncoderSettings();
    final recording =
        ref.watch(recordingSettingsProvider).value ?? const RecordingSettings();
    final camera =
        ref.watch(cameraSettingsProvider).value ?? const CameraSettings();
    final returnFeed =
        ref.watch(returnFeedConfigProvider).value ?? const ReturnFeedConfig();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (returnFeed.lockedSections.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock, size: 16, color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Managed by your station admin: '
                      '${returnFeed.lockedSections.join(", ")}',
                      style: const TextStyle(fontSize: 12, color: Colors.amber),
                    ),
                  ),
                ],
              ),
            ),
          _sectionHeader('Destinations'),
          for (final preset in presets)
            Card(
              color: ControlRoomColors.surface,
              child: ListTile(
                leading: IconButton(
                  icon: Icon(
                    preset.isDefault ? Icons.star : Icons.star_border,
                    color: preset.isDefault ? Colors.amber : Colors.white38,
                  ),
                  onPressed: returnFeed.lockedSections.contains('destinations')
                      ? null
                      : () => ref
                            .read(presetsProvider.notifier)
                            .setDefault(preset.id),
                ),
                title: Row(
                  children: [
                    Text(preset.name),
                    if (preset.isDefault) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'DEFAULT',
                          style: TextStyle(
                            color: Colors.amber,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  '${preset.protocol.name.toUpperCase()} · ${preset.displayTarget}',
                  style: const TextStyle(
                    color: ControlRoomColors.textSecondary,
                  ),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: returnFeed.lockedSections.contains('destinations')
                      ? null
                      : () => ref
                            .read(presetsProvider.notifier)
                            .remove(preset.id),
                ),
                onTap: returnFeed.lockedSections.contains('destinations')
                    ? null
                    : () => _editPreset(context, ref, preset),
              ),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add destination'),
            onPressed: returnFeed.lockedSections.contains('destinations')
                ? null
                : () => _editPreset(
                    context,
                    ref,
                    DestinationPreset(
                      id: DateTime.now().microsecondsSinceEpoch.toString(),
                      name: 'Station',
                    ),
                  ),
          ),
          const SizedBox(height: 24),
          _sectionHeader('Radio'),
          _RadioLineCard(),
          const SizedBox(height: 24),
          _sectionHeader('Encoder'),
          _EncoderSection(encoder: encoder),
          const SizedBox(height: 24),
          _sectionHeader('Recording'),
          _RecordingSection(recording: recording),
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

/// Compact card for the SIP/EBU 3326 radio line, opens the line editor.
class _RadioLineCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset =
        ref.watch(sipPresetProvider).valueOrNull ?? const SipPreset();
    final status = !preset.enabled
        ? 'Radio line off'
        : !preset.isConfigured
        ? 'Not configured'
        : preset.displayTarget;
    return Card(
      color: ControlRoomColors.surface,
      child: ListTile(
        leading: Icon(
          Icons.radio,
          color: preset.enabled
              ? ControlRoomColors.tallyRed
              : ControlRoomColors.textSecondary,
        ),
        title: Text(preset.name),
        subtitle: Text(
          'SIP · $status',
          style: const TextStyle(color: ControlRoomColors.textSecondary),
        ),
        trailing: Icon(
          preset.adminLocked ? Icons.lock : Icons.chevron_right,
          size: 18,
          color: preset.adminLocked ? Colors.amber : null,
        ),
        onTap: preset.adminLocked
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SipPresetEditorScreen(),
                ),
              ),
      ),
    );
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
                ButtonSegment(
                  value: BroadcastProtocol.webrtc,
                  label: Text('WebRTC'),
                ),
              ],
              selected: {_preset.protocol},
              onSelectionChanged: (selection) => setState(
                () => _preset = _preset.copyWith(protocol: selection.first),
              ),
            ),
            const SizedBox(height: 12),
            switch (_preset.protocol) {
              BroadcastProtocol.srt => _srtFields(),
              BroadcastProtocol.rtmp => _rtmpFields(),
              BroadcastProtocol.webrtc => _webrtcFields(),
            },
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Default Destination'),
              subtitle: const Text(
                'Automatically use this destination when streaming',
              ),
              value: _preset.isDefault,
              onChanged: (v) =>
                  setState(() => _preset = _preset.copyWith(isDefault: v)),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _webrtcFields() {
    return Column(
      children: [
        TextFormField(
          initialValue: _preset.webrtcUrl,
          decoration: const InputDecoration(
            labelText: 'WebRTC WebSocket / WHEP URL',
            hintText: 'e.g. ws://75.119.149.43:3333/app/stream',
          ),
          validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          onSaved: (v) => _preset = _preset.copyWith(webrtcUrl: v),
        ),
      ],
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
    final locked =
        ref
            .watch(returnFeedConfigProvider)
            .valueOrNull
            ?.lockedSections
            .contains('encoder') ??
        false;
    if (locked) return const _LockedCard(label: 'Encoder');
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
            _row(
              'OLED Power Saver (Auto-dim when idle)',
              Switch(
                value: encoder.oledPowerSaverEnabled,
                onChanged: (v) =>
                    notifier.save(encoder.copyWith(oledPowerSaverEnabled: v)),
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

class _RecordingSection extends ConsumerWidget {
  const _RecordingSection({required this.recording});

  final RecordingSettings recording;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked =
        ref
            .watch(returnFeedConfigProvider)
            .valueOrNull
            ?.lockedSections
            .contains('recording') ??
        false;
    if (locked) return const _LockedCard(label: 'Recording');
    final notifier = ref.read(recordingSettingsProvider.notifier);
    return Card(
      color: ControlRoomColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(
              'Resolution',
              DropdownButton<RecordingResolution>(
                value: recording.resolution,
                items: [
                  for (final r in RecordingResolution.values)
                    DropdownMenuItem(
                      value: r,
                      child: Text(_resolutionLabel(r)),
                    ),
                ],
                onChanged: (r) => r == null
                    ? null
                    : notifier.save(recording.copyWith(resolution: r)),
              ),
            ),
            _row(
              'Frame rate',
              DropdownButton<RecordingFps>(
                value: recording.fps,
                items: [
                  for (final f in RecordingFps.values)
                    DropdownMenuItem(value: f, child: Text(f.label)),
                ],
                onChanged: (fps) => fps == null
                    ? null
                    : notifier.save(recording.copyWith(fps: fps)),
              ),
            ),
            _row(
              'Codec',
              DropdownButton<BroadcastVideoCodec>(
                value: recording.codec,
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
                    : notifier.save(recording.copyWith(codec: codec)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Bitrate: ${(recording.bitrateBps / 1_000_000).toStringAsFixed(1)} Mb/s',
              style: const TextStyle(fontSize: 13),
            ),
            Slider(
              value: recording.bitrateBps.toDouble(),
              min: 2000000,
              max: 12000000,
              divisions: 20,
              onChanged: (v) =>
                  notifier.save(recording.copyWith(bitrateBps: v.round())),
            ),
            const SizedBox(height: 8),
            _row(
              'Enabled',
              Switch(
                value: recording.enabled,
                onChanged: (v) => notifier.save(recording.copyWith(enabled: v)),
              ),
            ),
            const Text(
              'Recordings save to Movies/StationCast with timestamp. View in Gallery or file manager.',
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

  String _resolutionLabel(RecordingResolution resolution) {
    switch (resolution) {
      case RecordingResolution.p720:
        return '720p';
      case RecordingResolution.p1080:
        return '1080p';
      case RecordingResolution.p1440:
        return '1440p';
    }
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
    final locked = config.lockedSections;
    final lockReturn = locked.contains('returnFeed');
    final lockBroadcaster = locked.contains('broadcaster');
    final lockTalkback = locked.contains('talkback');
    return Card(
      color: ControlRoomColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              initialValue: config.url,
              readOnly: lockReturn,
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
              readOnly: lockReturn,
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
              readOnly: lockReturn,
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
                  onChanged: lockReturn
                      ? null
                      : (m) => m == null
                            ? null
                            : notifier.save(config.copyWith(srtSenderMode: m)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Return feed resolution'),
                DropdownButton<int>(
                  value: const [0, 1080, 720, 480].contains(config.maxHeight)
                      ? config.maxHeight
                      : 0,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Full')),
                    DropdownMenuItem(value: 1080, child: Text('1080p')),
                    DropdownMenuItem(value: 720, child: Text('720p')),
                    DropdownMenuItem(value: 480, child: Text('480p')),
                  ],
                  onChanged: lockReturn
                      ? null
                      : (h) => h == null
                            ? null
                            : notifier.save(config.copyWith(maxHeight: h)),
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
                  onChanged: lockReturn
                      ? null
                      : (b) => b == null
                            ? null
                            : notifier.save(config.copyWith(backend: b)),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show automatically when going live'),
              value: config.autoplayOnLive,
              onChanged: lockReturn
                  ? null
                  : (v) => notifier.save(config.copyWith(autoplayOnLive: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Start muted (echo protection)'),
              value: config.startMuted,
              onChanged: lockReturn
                  ? null
                  : (v) => notifier.save(config.copyWith(startMuted: v)),
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
              readOnly: lockBroadcaster,
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
              readOnly: lockBroadcaster,
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
              onChanged: lockTalkback
                  ? null
                  : (v) => notifier.save(config.copyWith(talkbackEnabled: v)),
            ),
            TextFormField(
              initialValue: config.talkbackUrl,
              decoration: const InputDecoration(
                labelText: 'Talkback SRT URL',
                hintText: 'srt://talkback.server.com:port',
              ),
              enabled: config.talkbackEnabled && !lockTalkback,
              onChanged: (v) => notifier.save(config.copyWith(talkbackUrl: v)),
            ),
            TextFormField(
              initialValue: '${config.talkbackLatencyMs}',
              decoration: const InputDecoration(
                labelText: 'Talkback latency (ms)',
              ),
              keyboardType: TextInputType.number,
              enabled: config.talkbackEnabled && !lockTalkback,
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
              enabled: config.talkbackEnabled && !lockTalkback,
              onChanged: (v) =>
                  notifier.save(config.copyWith(talkbackPassphrase: v)),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockedCard extends StatelessWidget {
  const _LockedCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: ControlRoomColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.lock, size: 16, color: Colors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$label settings are managed by your station admin.',
                style: const TextStyle(
                  fontSize: 12,
                  color: ControlRoomColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

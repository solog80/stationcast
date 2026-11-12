import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../broadcast/providers.dart';
import '../models/sip_preset.dart';
import '../radio/radio_controller.dart';
import '../radio/providers.dart';
import '../services/radio_directory.dart';
import '../theme/control_room_theme.dart';
import 'widgets/audio_meter.dart';
import 'widgets/sip_preset_editor.dart';

/// Full-screen radio contribution page.
///
/// Registers the field device with the studio SIP registrar (Asterisk) as the
/// configured [SipPreset], then answers the studio console calling in over
/// EBU 3326. Audio-only: no camera, talks straight to the station's mixer.
class RadioScreen extends ConsumerStatefulWidget {
  const RadioScreen({super.key, this.onSwitchToTv});

  /// Called when the operator switches back to the TV/SRT broadcast page.
  final VoidCallback? onSwitchToTv;

  @override
  ConsumerState<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends ConsumerState<RadioScreen> {
  bool _permissionsDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setUp());
  }

  Future<void> _setUp() async {
    // Ensure the TV/Camera engine is completely released when on the Radio screen.
    try {
      await ref.read(broadcastControllerProvider.notifier).releaseEngine();
    } catch (_) {}
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) setState(() => _permissionsDenied = true);
      return;
    }
    final preset = await ref.read(sipPresetProvider.future);
    final ctrl = ref.read(radioControllerProvider.notifier);
    await ctrl.initialize(preset);
    if (preset.enabled && preset.isConfigured) {
      await ctrl.register(preset);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionsDenied) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.mic_off,
                  size: 56,
                  color: ControlRoomColors.tallyRed,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Microphone access is required for radio contribution.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => openAppSettings(),
                  child: const Text('Open system settings'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final presenters =
        ref.watch(radioPresentersProvider).valueOrNull ??
        const <RadioPresenter>[];
    final preset =
        ref.watch(sipPresetProvider).valueOrNull ?? const SipPreset();

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return CustomScrollView(
              physics: presenters.isEmpty
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                        children: [
                          _RadioTopBar(onSwitchToTv: widget.onSwitchToTv),
                          const SizedBox(height: 12),
                          Expanded(child: _RadioConsole()),
                          if (presenters.isNotEmpty)
                            _PresentersHint(count: presenters.length),
                          const SizedBox(height: 10),
                          const _RadioControls(),
                        ],
                      ),
                    ),
                  ),
                ),
                if (presenters.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _ConnectedPresentersSection(
                      presenters: presenters,
                      currentExtension: preset.extension,
                    ),
                  ),
                if (presenters.isNotEmpty)
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RadioTopBar extends ConsumerWidget {
  const _RadioTopBar({this.onSwitchToTv});

  final VoidCallback? onSwitchToTv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Text(
          'RADIO',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
            color: ControlRoomColors.textSecondary,
          ),
        ),
        const SizedBox(width: 10),
        if (onSwitchToTv != null)
          TextButton.icon(
            onPressed: onSwitchToTv,
            icon: const Icon(Icons.videocam_outlined, size: 16),
            label: const Text('TV'),
          ),
        const Spacer(),
        _TopIconButton(
          icon: Icons.settings,
          tooltip: 'Radio line settings',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const SipPresetEditorScreen(),
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-bleed "console" card: status header, big TX/RX meters, call stats.
class _RadioConsole extends ConsumerWidget {
  const _RadioConsole();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(radioControllerProvider);
    final preset =
        ref.watch(sipPresetProvider).valueOrNull ?? const SipPreset();

    final (headline, color) = switch (state.mode) {
      RadioMode.idle => (
        preset.isConfigured ? 'STANDBY' : 'RADIO LINE NOT SET UP',
        ControlRoomColors.textSecondary,
      ),
      RadioMode.registering => (
        'CONNECTING TO STUDIO',
        ControlRoomColors.amber,
      ),
      RadioMode.ready => (
        'READY — AWAITING CALL',
        ControlRoomColors.meterGreen,
      ),
      RadioMode.incoming => ('INCOMING CALL', ControlRoomColors.amber),
      RadioMode.connecting => ('CONNECTING AUDIO', ControlRoomColors.amber),
      RadioMode.onAir => ('ON AIR', ControlRoomColors.tallyRed),
      RadioMode.failed => ('LINK FAILED', ControlRoomColors.tallyRed),
    };

    final subtitle = switch (state.mode) {
      RadioMode.idle =>
        preset.isConfigured
            ? preset.displayTarget
            : 'Add your radio line in settings to get on air',
      RadioMode.registering => preset.displayTarget,
      RadioMode.ready => preset.displayTarget,
      RadioMode.incoming =>
        state.peer.isNotEmpty ? state.peer : 'Studio calling…',
      RadioMode.connecting => state.peer,
      RadioMode.onAir =>
        state.peer.isNotEmpty ? state.peer : 'Studio · two-way live',
      RadioMode.failed => state.errorMessage ?? 'Radio link failed',
    };

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: ControlRoomColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ControlRoomColors.outline),
      ),
      child: Column(
        children: [
          // Status header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: ControlRoomColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (state.isOnAir)
                  _CallTimer(connectedSince: state.connectedSince),
              ],
            ),
          ),
          if (state.errorMessage != null && state.mode == RadioMode.failed) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                state.errorMessage!,
                style: const TextStyle(
                  color: ControlRoomColors.tallyRed,
                  fontSize: 12,
                ),
              ),
            ),
          ],
          // Meters fill remaining space
          const Expanded(child: _MeterConsole()),
          // Footer stats while live
          if (state.isOnAir) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: ControlRoomColors.surfaceRaised,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(16),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _StatChip(
                    icon: Icons.graphic_eq,
                    label: state.codec.isEmpty ? 'two-way' : state.codec,
                  ),
                  const SizedBox(width: 10),
                  const _RttChip(),
                  const SizedBox(width: 10),
                  const _CodecChip(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Big vertical channel meters (TX/RX) with peak hold, filling the console.
class _MeterConsole extends ConsumerWidget {
  const _MeterConsole();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(radioStatsProvider).value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _ChannelMeter(
              label: 'TX',
              icon: Icons.mic,
              levels: stats?.audioLevelDb ?? const [-60.0, -60.0],
              color: ControlRoomColors.meterGreen,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _ChannelMeter(
              label: 'RX',
              icon: Icons.volume_down,
              levels: stats?.rxAudioLevelDb ?? const [-60.0, -60.0],
              color: ControlRoomColors.amber,
            ),
          ),
        ],
      ),
    );
  }
}

/// One full-height channel meter using the TV page's broadcast ballistics & painter.
class _ChannelMeter extends StatefulWidget {
  const _ChannelMeter({
    required this.label,
    required this.icon,
    required this.levels,
    required this.color,
  });

  final String label;
  final IconData icon;
  final List<double> levels;
  final Color color;

  @override
  State<_ChannelMeter> createState() => _ChannelMeterState();
}

class _ChannelMeterState extends State<_ChannelMeter>
    with SingleTickerProviderStateMixin {
  late AnimationController _ticker;
  DateTime _lastTime = DateTime.now();

  AudioMeterChannelState _leftChannel = const AudioMeterChannelState();
  AudioMeterChannelState _rightChannel = const AudioMeterChannelState();

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _ticker.addListener(_onFrame);
    _lastTime = DateTime.now();
  }

  @override
  void didUpdateWidget(_ChannelMeter old) {
    super.didUpdateWidget(old);
    _onFrame();
  }

  void _onFrame() {
    final now = DateTime.now();
    final dt = now.difference(_lastTime).inMicroseconds / 1000000.0;
    _lastTime = now;
    if (dt <= 0) return;

    final inL = widget.levels.isNotEmpty
        ? widget.levels[0]
        : AudioMeterBallistics.floorDb;
    final inR = widget.levels.length > 1 ? widget.levels[1] : inL;

    final nextL = _leftChannel.step(inL, dt);
    final nextR = _rightChannel.step(inR, dt);

    if (nextL.levelDb != _leftChannel.levelDb ||
        nextL.peakDb != _leftChannel.peakDb ||
        nextR.levelDb != _rightChannel.levelDb ||
        nextR.peakDb != _rightChannel.peakDb) {
      setState(() {
        _leftChannel = nextL;
        _rightChannel = nextR;
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxLevel = _leftChannel.levelDb > _rightChannel.levelDb
        ? _leftChannel.levelDb
        : _rightChannel.levelDb;
    final maxPeak = _leftChannel.peakDb > _rightChannel.peakDb
        ? _leftChannel.peakDb
        : _rightChannel.peakDb;

    final levelLabel = maxLevel <= -59.5 ? '-∞' : '${maxLevel.round()}';
    final peakLabel = maxPeak <= -59.5 ? '-∞' : '${maxPeak.round()}';

    final leftLevelFrac =
        ((_leftChannel.levelDb - AudioMeterBallistics.floorDb) /
                (-AudioMeterBallistics.floorDb))
            .clamp(0.0, 1.0);
    final leftPeakFrac =
        ((_leftChannel.peakDb - AudioMeterBallistics.floorDb) /
                (-AudioMeterBallistics.floorDb))
            .clamp(0.0, 1.0);

    final rightLevelFrac =
        ((_rightChannel.levelDb - AudioMeterBallistics.floorDb) /
                (-AudioMeterBallistics.floorDb))
            .clamp(0.0, 1.0);
    final rightPeakFrac =
        ((_rightChannel.peakDb - AudioMeterBallistics.floorDb) /
                (-AudioMeterBallistics.floorDb))
            .clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: ControlRoomColors.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ControlRoomColors.outline),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(widget.icon, size: 16, color: widget.color),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: widget.color,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              Text(
                '$levelLabel dB',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: ControlRoomColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: CustomPaint(
                    painter: BroadcastMeterPainter(
                      levelFraction: leftLevelFrac,
                      peakFraction: leftPeakFrac,
                      peakDb: _leftChannel.peakDb,
                      borderRadius: 4.0,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: CustomPaint(
                    painter: BroadcastMeterPainter(
                      levelFraction: rightLevelFrac,
                      peakFraction: rightPeakFrac,
                      peakDb: _rightChannel.peakDb,
                      borderRadius: 4.0,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'L',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'peak $peakLabel',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: ControlRoomColors.textSecondary,
                ),
              ),
              const Text(
                'R',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: ControlRoomColors.amber),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _RttChip extends ConsumerWidget {
  const _RttChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(radioStatsProvider).value;
    final rtt = stats?.rttMs ?? 0.0;
    return _StatChip(icon: Icons.speed, label: '${rtt.toStringAsFixed(0)} ms');
  }
}

class _CodecChip extends ConsumerWidget {
  const _CodecChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(radioControllerProvider);
    final codec = state.codec.isEmpty ? 'G.722' : state.codec;
    return _StatChip(icon: Icons.circle, label: codec);
  }
}

class _CallTimer extends StatefulWidget {
  const _CallTimer({this.connectedSince});

  final DateTime? connectedSince;

  @override
  State<_CallTimer> createState() => _CallTimerState();
}

class _CallTimerState extends State<_CallTimer> {
  @override
  Widget build(BuildContext context) {
    final since = widget.connectedSince;
    if (since == null) return const SizedBox.shrink();
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(seconds: 1), (i) => i),
      builder: (context, _) {
        final elapsed = DateTime.now().difference(since);
        final m = elapsed.inMinutes.toString().padLeft(2, '0');
        final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '$m:$s',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 26,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
                color: ControlRoomColors.textPrimary,
              ),
            ),
            const Text(
              'LIVE',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 2,
                color: ControlRoomColors.tallyRed,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RadioControls extends ConsumerWidget {
  const _RadioControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(radioControllerProvider);
    final ctrl = ref.read(radioControllerProvider.notifier);
    final preset =
        ref.watch(sipPresetProvider).valueOrNull ?? const SipPreset();

    // Incoming call → Answer / Decline.
    if (state.mode == RadioMode.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RoundButton(
            label: 'Decline',
            icon: Icons.call_end,
            color: ControlRoomColors.textSecondary,
            onPressed: ctrl.decline,
          ),
          const SizedBox(width: 40),
          _RoundButton(
            label: 'Answer',
            icon: Icons.call,
            color: ControlRoomColors.meterGreen,
            onPressed: ctrl.accept,
          ),
        ],
      );
    }

    if (state.isOnAir) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RoundButton(
            label: 'End call',
            icon: Icons.call_end,
            color: ControlRoomColors.tallyRed,
            onPressed: ctrl.hangup,
          ),
        ],
      );
    }

    // Idle / ready / registering / failed.
    final connecting = state.mode == RadioMode.registering;
    final canRegister =
        state.mode == RadioMode.idle ||
        state.mode == RadioMode.failed ||
        state.mode == RadioMode.ready;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundButton(
          label: connecting
              ? 'Connecting…'
              : state.mode == RadioMode.ready
              ? 'Disconnect'
              : 'Connect',
          icon: connecting
              ? Icons.hourglass_top
              : state.mode == RadioMode.ready
              ? Icons.link_off
              : Icons.link,
          color: ControlRoomColors.meterGreen,
          enabled: canRegister || connecting,
          onPressed: () {
            if (connecting) return;
            if (state.mode == RadioMode.ready) {
              ctrl.unregister();
            } else if (preset.isConfigured) {
              ctrl.register(preset);
            } else {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SipPresetEditorScreen(),
                ),
              );
            }
          },
        ),
        // Call Studio — only meaningful once registered (Ready).
        if (state.mode == RadioMode.ready)
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: _RoundButton(
              label: 'Call Studio',
              icon: Icons.radio,
              color: ControlRoomColors.tallyRed,
              enabled: state.mode == RadioMode.ready,
              onPressed: () => ctrl.callStudio(preset),
            ),
          ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final on = enabled ? onPressed : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color.withValues(alpha: 0.18),
          shape: const CircleBorder(),
          child: IconButton(
            onPressed: on,
            iconSize: 34,
            padding: const EdgeInsets.all(20),
            color: enabled ? color : color.withValues(alpha: 0.35),
            icon: Icon(icon),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: enabled
                ? ControlRoomColors.textSecondary
                : ControlRoomColors.textSecondary.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }
}

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, color: ControlRoomColors.textSecondary),
    );
  }
}

/// Small affordance above the call controls: more content is one swipe away.
class _PresentersHint extends StatelessWidget {
  const _PresentersHint({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count == 1 ? '1 presenter' : '$count presenters';
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.keyboard_arrow_up,
            size: 16,
            color: ControlRoomColors.textSecondary,
          ),
          const SizedBox(width: 4),
          Text(
            '$label in the studio · swipe up',
            style: const TextStyle(
              fontSize: 11,
              color: ControlRoomColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Second, scrollable page: who is currently connected to the studio.
class _ConnectedPresentersSection extends StatelessWidget {
  const _ConnectedPresentersSection({
    required this.presenters,
    required this.currentExtension,
  });

  final List<RadioPresenter> presenters;
  final String currentExtension;

  @override
  Widget build(BuildContext context) {
    final current = currentExtension.trim().toLowerCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'IN THE STUDIO',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                  color: ControlRoomColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${presenters.length} connected',
                style: const TextStyle(
                  fontSize: 12,
                  color: ControlRoomColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Connected presenters',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: ControlRoomColors.textPrimary,
            ),
          ),
          const SizedBox(height: 14),
          for (final presenter in presenters)
            _PresenterRow(
              presenter: presenter,
              isYou:
                  current.isNotEmpty &&
                  presenter.extension.trim().toLowerCase() == current,
            ),
          const SizedBox(height: 8),
          const Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: ControlRoomColors.textSecondary,
                ),
                SizedBox(width: 4),
                Text(
                  'Swipe down to return',
                  style: TextStyle(
                    fontSize: 11,
                    color: ControlRoomColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PresenterRow extends StatelessWidget {
  const _PresenterRow({required this.presenter, required this.isYou});

  final RadioPresenter presenter;
  final bool isYou;

  static const _avatarColors = [
    ControlRoomColors.meterGreen,
    ControlRoomColors.amber,
    ControlRoomColors.tallyRed,
    Color(0xFF5B8DEF),
    Color(0xFFB565FF),
    Color(0xFF20C4C4),
  ];

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    final list = parts.toList();
    if (list.length == 1) {
      return list.first
          .substring(0, list.first.length.clamp(1, 2))
          .toUpperCase();
    }
    return '${list.first[0]}${list.last[0]}'.toUpperCase();
  }

  static Color _avatarColor(String name) {
    var hash = 0;
    for (var i = 0; i < name.length; i++) {
      hash = (hash * 31 + name.codeUnitAt(i)) & 0x7fffffff;
    }
    return _avatarColors[hash % _avatarColors.length];
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = presenter.extension.isNotEmpty
        ? presenter.extension
        : presenter.callerId;
    final avatarColor = _avatarColor(presenter.displayName);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ControlRoomColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ControlRoomColors.outline),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 21,
            backgroundColor: avatarColor.withValues(alpha: 0.2),
            foregroundColor: avatarColor,
            foregroundImage: presenter.avatarUrl.trim().isNotEmpty
                ? NetworkImage(presenter.avatarUrl.trim())
                : null,
            onForegroundImageError: presenter.avatarUrl.trim().isNotEmpty
                ? (_, __) {}
                : null,
            child: Text(
              _initials(presenter.displayName),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        presenter.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: ControlRoomColors.textPrimary,
                        ),
                      ),
                    ),
                    if (isYou) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: ControlRoomColors.amber.withValues(
                            alpha: 0.15,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'YOU',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: ControlRoomColors.amber,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: ControlRoomColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color:
                  (presenter.muted
                          ? ControlRoomColors.textSecondary
                          : ControlRoomColors.tallyRed)
                      .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              presenter.muted ? 'MUTED' : 'ON AIR',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: presenter.muted
                    ? ControlRoomColors.textSecondary
                    : ControlRoomColors.tallyRed,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

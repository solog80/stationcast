import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../broadcast/broadcast_controller.dart';
import '../broadcast/providers.dart';
import '../models/destination_preset.dart';
import '../return_feed/return_feed_controller.dart';
import '../services/broadcast_reporter.dart';
import '../talkback/talkback_controller.dart';
import '../theme/control_room_theme.dart';
import '../utils/log.dart';
import 'settings_screen.dart';
import 'widgets/audio_meter.dart';
import 'widgets/camera_controls_strip.dart';
import 'widgets/control_bar.dart';
import 'widgets/frame_guides_overlay.dart';
import 'widgets/histogram_overlay.dart';
import 'widgets/floating_return_feed.dart';
import 'widgets/health_overlay.dart';
import 'widgets/on_air_indicator.dart';
import 'widgets/talkback_indicator.dart';

// Static camera instance created once and never recreated

class BroadcastScreen extends ConsumerStatefulWidget {
  const BroadcastScreen({super.key});

  @override
  ConsumerState<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends ConsumerState<BroadcastScreen>
    with WidgetsBindingObserver {
  bool _permissionsDenied = false;
  bool _chromeVisible = true;
  bool _cameraSettingsOpen = false;
  Timer? _chromeTimer;
  Timer? _statusTimer;
  Timer? _snapshotTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setUp());
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chromeTimer?.cancel();
    _statusTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Camera stays active for streaming; dim overlay saves OLED power
  }

  Future<void> _setUp() async {
    final statuses = await [Permission.camera, Permission.microphone].request();
    final granted = statuses.values.every((s) => s.isGranted);
    if (!granted) {
      setState(() => _permissionsDenied = true);
      return;
    }
    final encoder = await ref.read(encoderSettingsProvider.future);
    await ref.read(broadcastControllerProvider.notifier).initialize(encoder);
    _restartChromeTimer();
  }

  void _restartChromeTimer() {
    _chromeTimer?.cancel();
    // Keep UI visible at all times for broadcast app - operators need quick access
    // _chromeTimer = Timer(const Duration(seconds: 5), () {
    //   if (mounted && ref.read(broadcastControllerProvider).isLive) {
    //     setState(() => _chromeVisible = false);
    //   }
    // });
  }

  void _onScreenTap() {
    setState(() => _chromeVisible = true);
    _restartChromeTimer();
  }

  Future<void> _goLive() async {
    final presets = await ref.read(presetsProvider.future);
    if (!mounted) return;
    if (presets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add a destination preset in settings first'),
        ),
      );
      _openSettings();
      return;
    }
    final preset = presets.length == 1
        ? presets.first
        : await _pickPreset(presets);
    if (preset == null) return;
    await ref.read(broadcastControllerProvider.notifier).goLive(preset);
    _reportStatus(true, preset);
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _reportStatus(true, preset),
    );
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _takeSnapshot(),
    );
    final feedConfig = await ref.read(returnFeedConfigProvider.future);
    if (feedConfig.autoplayOnLive && feedConfig.url.isNotEmpty) {
      await ref.read(returnFeedControllerProvider.notifier).show();
    }
  }

  Future<DestinationPreset?> _pickPreset(List<DestinationPreset> presets) {
    return showModalBottomSheet<DestinationPreset>(
      context: context,
      backgroundColor: ControlRoomColors.surface,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Send to',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final preset in presets)
              ListTile(
                title: Text(preset.name),
                subtitle: Text(
                  preset.displayTarget,
                  style: const TextStyle(
                    color: ControlRoomColors.textSecondary,
                  ),
                ),
                leading: const Icon(Icons.cell_tower),
                onTap: () => Navigator.of(context).pop(preset),
              ),
          ],
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  Future<void> _takeSnapshot() async {
    final config = ref.read(returnFeedConfigProvider).valueOrNull;
    if (config == null || config.broadcasterId.isEmpty) return;
    try {
      final bytes = await ref.read(broadcastPluginProvider).takeSnapshot();
      if (bytes != null && mounted) {
        await ref
            .read(broadcastReporterProvider)
            .uploadSnapshot(config.broadcasterId, bytes);
      }
    } catch (_) {}
  }

  Future<void> _reportStatus(bool isLive, [DestinationPreset? preset]) async {
    final config = ref.read(returnFeedConfigProvider).valueOrNull;
    if (config == null || config.broadcasterId.isEmpty) return;
    final state = ref.read(broadcastControllerProvider);
    final stats = ref.read(statsProvider).valueOrNull;
    final feedState = ref.read(returnFeedControllerProvider);
    final streamUrl = preset != null
        ? preset.protocol == BroadcastProtocol.srt
              ? 'srt://${preset.host}:${preset.port}${preset.streamId.isNotEmpty ? '?streamid=${preset.streamId}' : ''}'
              : preset.rtmpUrl.isNotEmpty
              ? '${preset.rtmpUrl}/${preset.streamKey}'
              : ''
        : '';
    await ref
        .read(broadcastReporterProvider)
        .reportStatus(
          broadcasterId: config.broadcasterId,
          broadcasterName: config.broadcasterName,
          isLive: isLive,
          uptime: state.liveSince != null
              ? DateTime.now().difference(state.liveSince!).inSeconds
              : 0,
          bitrate: stats?.bitrateBps ?? 0,
          rttMs: stats?.rttMs ?? 0.0,
          packetsDropped: stats?.packetsDropped ?? 0,
          returnFeedUrl: config.url,
          talkbackActive: feedState.visible,
          streamUrl: streamUrl,
        );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final orientation = MediaQuery.of(context).orientation;
    log('[BroadcastScreen] build: ${size.width}x${size.height} ($orientation)');

    final state = ref.watch(broadcastControllerProvider);
    final stats = ref.watch(statsProvider).value;
    final feedState = ref.watch(returnFeedControllerProvider);

    // Auto-start/stop talkback when going live
    ref.watch(talkbackAutoProvider);

    // Report offline when broadcast stops
    final wasLive = ref.watch(
      broadcastControllerProvider.select(
        (s) =>
            s.connection == BroadcastConnectionState.live ||
            s.connection == BroadcastConnectionState.connecting,
      ),
    );
    if (!wasLive && _statusTimer != null) {
      _statusTimer?.cancel();
      _statusTimer = null;
      _snapshotTimer?.cancel();
      _snapshotTimer = null;
      _reportStatus(false);
    }

    if (_permissionsDenied) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off,
                size: 48,
                color: ControlRoomColors.amber,
              ),
              const SizedBox(height: 12),
              const Text(
                'Camera and microphone access is required to broadcast.',
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: openAppSettings,
                child: const Text('Open system settings'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _onScreenTap,
        child: _BroadcastLayout(
          state: state,
          stats: stats,
          feedState: feedState,
          chromeVisible: _chromeVisible,
          cameraSettingsOpen: _cameraSettingsOpen,
          onCameraSettingsToggle: () =>
              setState(() => _cameraSettingsOpen = !_cameraSettingsOpen),
          onGoLive: _goLive,
          onOpenSettings: _openSettings,
        ),
      ),
    );
  }
}

class _BroadcastLayout extends ConsumerWidget {
  final BroadcastUiState state;
  final StreamStats? stats;
  final ReturnFeedUiState feedState;
  final bool chromeVisible;
  final bool cameraSettingsOpen;
  final VoidCallback onCameraSettingsToggle;
  final VoidCallback onGoLive;
  final VoidCallback onOpenSettings;

  const _BroadcastLayout({
    required this.state,
    required this.stats,
    required this.feedState,
    required this.chromeVisible,
    required this.cameraSettingsOpen,
    required this.onCameraSettingsToggle,
    required this.onGoLive,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.sizeOf(context);
    final orientation = MediaQuery.of(context).orientation;
    log(
      '[_BroadcastLayout] build: ${size.width}x${size.height} ($orientation)',
    );

    // Auto-hide system UI in landscape for immersive camera view
    SystemChrome.setEnabledSystemUIMode(
      orientation == Orientation.landscape
          ? SystemUiMode.immersiveSticky
          : SystemUiMode.edgeToEdge,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview layer - stays fixed, never rotates
        if (state.initialized)
          const _CameraLayer()
        else
          const Center(child: CircularProgressIndicator()),

        // UI overlays - rotate with device orientation (like Larix)
        OrientationBuilder(
          builder: (context, orientation) {
            return Stack(
              fit: StackFit.expand,
              children: [
                // Overlays layer - rebuilds independently
                _OverlaysLayer(
                  chromeVisible: chromeVisible,
                  cameraSettingsOpen: cameraSettingsOpen,
                  onCameraSettingsToggle: onCameraSettingsToggle,
                  state: state,
                  stats: stats,
                  feedState: feedState,
                  onGoLive: onGoLive,
                  onOpenSettings: onOpenSettings,
                ),

                // Floating return feed - separate from main layout
                _FloatingFeedLayer(),

                // Rotation transition overlay to mask native re-renders
                const _RotationTransitionMask(),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ChromeOverlay extends ConsumerWidget {
  final bool visible;
  final bool cameraSettingsOpen;
  final VoidCallback onCameraSettingsToggle;
  final BroadcastUiState state;
  final StreamStats? stats;
  final ReturnFeedUiState feedState;
  final VoidCallback onGoLive;
  final VoidCallback onOpenSettings;

  const _ChromeOverlay({
    required this.visible,
    required this.cameraSettingsOpen,
    required this.onCameraSettingsToggle,
    required this.state,
    required this.stats,
    required this.feedState,
    required this.onGoLive,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!visible) return const SizedBox.shrink();

    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    log('[_ChromeOverlay] build: isPortrait=$isPortrait');

    return RepaintBoundary(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              // Top bar — always visible
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OnAirIndicator(
                    connection: state.connection,
                    liveSince: state.liveSince,
                    reconnectAttempt: state.reconnectAttempt,
                  ),
                  const SizedBox(width: 10),
                  const TalkbackIndicator(),
                  const Spacer(),
                  _SleekIconButton(
                    icon: Icons.picture_in_picture_alt,
                    active: feedState.visible,
                    tooltip: 'Return feed',
                    onPressed: () {
                      final ctrl = ref.read(
                        returnFeedControllerProvider.notifier,
                      );
                      feedState.visible ? ctrl.hide() : ctrl.show();
                    },
                  ),
                  const SizedBox(width: 6),
                  _SleekIconButton(
                    icon: Icons.settings,
                    active: !state.isLive,
                    tooltip: 'Settings',
                    onPressed: state.isLive ? null : onOpenSettings,
                  ),
                ],
              ),
              const Spacer(),
              // Zoom pills
              const ZoomPills(),
              const SizedBox(height: 6),
              // Controls
              FittedBox(
                fit: BoxFit.scaleDown,
                child: ControlBar(
                  onGoLive: onGoLive,
                  onCameraSettingsPressed: onCameraSettingsToggle,
                  cameraSettingsActive: cameraSettingsOpen,
                ),
              ),
              // Metadata row — only when live, below controls
              if (state.isLive) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (stats != null) ...[
                      _MetaChip(
                        icon: Icons.arrow_upward,
                        label:
                            '${(stats!.bitrateBps / 1000000).toStringAsFixed(1)} Mbps',
                      ),
                      const SizedBox(width: 8),
                      _MetaChip(
                        icon: Icons.speed,
                        label: '${stats!.rttMs?.toStringAsFixed(0) ?? '?'} ms',
                      ),
                      const SizedBox(width: 8),
                      _MetaChip(
                        icon: Icons.warning_amber,
                        label: '${stats!.packetsDropped} drop',
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: ControlRoomColors.amber),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

class _SleekIconButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback? onPressed;
  const _SleekIconButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scale = (MediaQuery.sizeOf(context).shortestSide / 400).clamp(
      0.8,
      1.6,
    );
    final iconSize = (14 * scale).roundToDouble();
    final child = Container(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 8 * scale,
            vertical: 4 * scale,
          ),
          child: Icon(
            icon,
            size: iconSize,
            color: active ? ControlRoomColors.amber : Colors.white54,
          ),
        ),
      ),
    );
    return tooltip.isEmpty ? child : Tooltip(message: tooltip, child: child);
  }
}

class _RotationTransitionMask extends StatefulWidget {
  const _RotationTransitionMask();

  @override
  State<_RotationTransitionMask> createState() =>
      _RotationTransitionMaskState();
}

class _RotationTransitionMaskState extends State<_RotationTransitionMask>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  Orientation? _lastOrientation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentOrientation = MediaQuery.of(context).orientation;

    if (_lastOrientation != null && _lastOrientation != currentOrientation) {
      log('[RotationTransitionMask] orientation changed, masking blackout');
      _animController.forward(from: 0);
    }
    _lastOrientation = currentOrientation;
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fadeAnim,
      builder: (context, child) {
        final opacity = _fadeAnim.value;
        if (opacity == 0) return const SizedBox.shrink();
        return IgnorePointer(
          child: RepaintBoundary(
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: Colors.black.withValues(alpha: 0.25 * opacity),
            ),
          ),
        );
      },
    );
  }
}

class _FloatingFeedLayer extends StatelessWidget {
  const _FloatingFeedLayer();

  @override
  Widget build(BuildContext context) {
    log('[_FloatingFeedLayer] build');
    return const FloatingReturnFeed();
  }
}

class _CameraLayer extends ConsumerStatefulWidget {
  const _CameraLayer();

  @override
  ConsumerState<_CameraLayer> createState() => _CameraLayerState();
}

class _CameraLayerState extends ConsumerState<_CameraLayer>
    with SingleTickerProviderStateMixin {
  AnimationController? _focusAnim;
  Offset? _focusPoint;

  void _onTap(TapUpDetails details) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final localPos = box.globalToLocal(details.globalPosition);
    final size = box.size;
    final x = (localPos.dx / size.width).clamp(0.0, 1.0);
    final y = (localPos.dy / size.height).clamp(0.0, 1.0);

    setState(() {
      _focusPoint = localPos;
      _focusAnim?.dispose();
      _focusAnim = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      );
      _focusAnim!.addListener(() {
        if (mounted) setState(() {});
      });
      _focusAnim!.addStatusListener((s) {
        if (s == AnimationStatus.completed) setState(() => _focusPoint = null);
      });
      _focusAnim!.forward();
    });

    ref.read(broadcastControllerProvider.notifier).setFocusPoint(x, y);
  }

  @override
  void dispose() {
    _focusAnim?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    log('[_CameraLayer] build');
    final orientation = MediaQuery.of(context).orientation;
    final cameraAspectRatio = ref
        .watch(broadcastControllerProvider)
        .cameraAspectRatio;
    final displayAspectRatio = orientation == Orientation.portrait
        ? 1.0 / cameraAspectRatio
        : cameraAspectRatio;

    return RepaintBoundary(
      child: GestureDetector(
        onTapUp: _onTap,
        child: Stack(
          children: [
            Center(
              child: Container(
                color: Colors.black,
                child: AspectRatio(
                  aspectRatio: displayAspectRatio,
                  child: const NativeCameraPreview(key: ValueKey('camera')),
                ),
              ),
            ),
            // Frame guides
            if (ref.watch(broadcastControllerProvider).showFrameGuides)
              const Positioned.fill(
                child: IgnorePointer(child: FrameGuidesOverlay()),
              ),

            if (_focusPoint != null)
              Positioned(
                left: _focusPoint!.dx - 30,
                top: _focusPoint!.dy - 30,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: ControlRoomColors.amber.withValues(
                        alpha: _focusAnim?.value ?? 1.0,
                      ),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OverlaysLayer extends ConsumerWidget {
  final bool chromeVisible;
  final bool cameraSettingsOpen;
  final VoidCallback onCameraSettingsToggle;
  final BroadcastUiState state;
  final StreamStats? stats;
  final ReturnFeedUiState feedState;
  final VoidCallback onGoLive;
  final VoidCallback onOpenSettings;

  const _OverlaysLayer({
    required this.chromeVisible,
    required this.cameraSettingsOpen,
    required this.onCameraSettingsToggle,
    required this.state,
    required this.stats,
    required this.feedState,
    required this.onGoLive,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.sizeOf(context);
    log('[_OverlaysLayer] build: ${size.width}x${size.height}');
    return Stack(
      fit: StackFit.expand,
      children: [
        // Chrome UI overlay
        _ChromeOverlay(
          visible: chromeVisible,
          state: state,
          stats: stats,
          feedState: feedState,
          cameraSettingsOpen: cameraSettingsOpen,
          onCameraSettingsToggle: onCameraSettingsToggle,
          onGoLive: onGoLive,
          onOpenSettings: onOpenSettings,
        ),

        // Camera controls strip — right edge in landscape
        if (chromeVisible &&
            MediaQuery.of(context).orientation == Orientation.landscape)
          Positioned(
            right: 8,
            top: 80,
            child: SingleChildScrollView(child: CameraControlsStrip()),
          ),

        // Audio meter
        if (chromeVisible && stats != null && state.isLive)
          Positioned(
            left: 12,
            top: 0,
            bottom: 0,
            child: RepaintBoundary(
              child: Center(child: AudioMeter(levelsDb: stats!.audioLevelDb)),
            ),
          ),

        // Histogram — inside safe area guide bottom-right
        if (chromeVisible && state.showHistogram)
          Positioned(
            right: size.width * 0.12,
            bottom: size.height * 0.12,
            child: const HistogramOverlay(),
          ),

        // Error message
        if (state.errorMessage != null &&
            state.connection == BroadcastConnectionState.failed)
          Positioned(
            left: 0,
            right: 0,
            bottom: 96,
            child: RepaintBoundary(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: ControlRoomColors.tallyRed.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    state.errorMessage!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),

        // Camera settings popup overlay
        if (cameraSettingsOpen)
          Positioned(
            right: 12,
            top: 80,
            width: 280,
            child: RepaintBoundary(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: ControlRoomColors.amber.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Camera Settings',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          IconButton(
                            onPressed: onCameraSettingsToggle,
                            icon: const Icon(Icons.close, size: 18),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _CameraSettingsPanel(),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // Dim overlay when chrome is hidden
        if (!chromeVisible)
          Positioned.fill(
            child: RepaintBoundary(
              child: Container(color: Colors.black.withValues(alpha: 0.4)),
            ),
          ),
      ],
    );
  }
}

class _CameraSettingsPanel extends ConsumerWidget {
  const _CameraSettingsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraAsync = ref.watch(cameraSettingsProvider);
    final broadcastState = ref.watch(broadcastControllerProvider);
    final capabilitiesFuture = ref.watch(cameraCapabilitiesFutureProvider);

    return cameraAsync.when(
      data: (camera) {
        return capabilitiesFuture.when(
          data: (capabilities) {
            final maxZoom =
                (capabilities['maxZoom'] as num?)?.toDouble() ??
                broadcastState.maxZoom;
            final actualMaxZoom = maxZoom;
            final zoomValue = camera.zoom.clamp(1.0, actualMaxZoom);
            final minExp = -16;
            final maxExp = 16;
            final expValue = camera.exposureCompensation.clamp(minExp, maxExp);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Exposure: $expValue ($minExp to $maxExp)',
                  style: const TextStyle(fontSize: 12),
                ),
                Slider(
                  value: expValue.toDouble(),
                  min: minExp.toDouble(),
                  max: maxExp.toDouble(),
                  divisions: 32,
                  label: expValue.toString(),
                  onChanged: (value) {
                    ref
                        .read(cameraSettingsProvider.notifier)
                        .save(
                          camera.copyWith(exposureCompensation: value.toInt()),
                        );
                  },
                ),
                const SizedBox(height: 12),
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Frame Guides',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: ref
                        .watch(broadcastControllerProvider)
                        .showFrameGuides,
                    onChanged: (_) => ref
                        .read(broadcastControllerProvider.notifier)
                        .toggleFrameGuides(),
                  ),
                ),
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Histogram',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: ref.watch(broadcastControllerProvider).showHistogram,
                    onChanged: (_) => ref
                        .read(broadcastControllerProvider.notifier)
                        .toggleHistogram(),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Zoom: ${zoomValue.toStringAsFixed(1)}x',
                  style: const TextStyle(fontSize: 12),
                ),
                Slider(
                  value: zoomValue,
                  min: 1.0,
                  max: actualMaxZoom,
                  onChanged: (value) {
                    ref
                        .read(cameraSettingsProvider.notifier)
                        .save(camera.copyWith(zoom: value));
                  },
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, stack) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Exposure: ${camera.exposureCompensation}',
                style: const TextStyle(fontSize: 12),
              ),
              Slider(
                value: camera.exposureCompensation.toDouble(),
                min: -16,
                max: 16,
                divisions: 32,
                label: camera.exposureCompensation.toString(),
                onChanged: (value) {
                  ref
                      .read(cameraSettingsProvider.notifier)
                      .save(
                        camera.copyWith(exposureCompensation: value.toInt()),
                      );
                },
              ),
              const SizedBox(height: 12),
              Text(
                'Zoom: ${camera.zoom.toStringAsFixed(1)}x',
                style: const TextStyle(fontSize: 12),
              ),
              Slider(
                value: camera.zoom,
                min: 1.0,
                max: 20.0,
                onChanged: (value) {
                  ref
                      .read(cameraSettingsProvider.notifier)
                      .save(camera.copyWith(zoom: value));
                },
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox(
        height: 100,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (err, stack) =>
          Text('Error: $err', style: const TextStyle(fontSize: 12)),
    );
  }
}

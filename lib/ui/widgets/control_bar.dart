import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../broadcast/broadcast_controller.dart';
import '../../broadcast/providers.dart';
import '../../theme/control_room_theme.dart';

/// Bottom control strip: camera flip, torch, mute, zoom popup, camera settings, GO LIVE / STOP.
class ControlBar extends ConsumerWidget {
  const ControlBar({
    super.key,
    required this.onGoLive,
    required this.onCameraSettingsPressed,
    required this.cameraSettingsActive,
  });

  /// Invoked when the operator hits GO LIVE (screen owns preset selection).
  final VoidCallback onGoLive;
  final VoidCallback onCameraSettingsPressed;
  final bool cameraSettingsActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(broadcastControllerProvider);
    final controller = ref.read(broadcastControllerProvider.notifier);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ControlRoomColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SlimButton(
            icon: Icons.cameraswitch,
            tooltip: 'Switch camera',
            onPressed: controller.switchCamera,
          ),
          _SlimButton(
            icon: state.torchOn ? Icons.flashlight_on : Icons.flashlight_off,
            tooltip: 'Torch',
            active: state.torchOn,
            onPressed: controller.toggleTorch,
          ),
          _SlimButton(
            icon: state.muted ? Icons.mic_off : Icons.mic,
            tooltip: 'Mute microphone',
            active: state.muted,
            activeColor: ControlRoomColors.tallyRed,
            onPressed: controller.toggleMute,
          ),
          if (state.maxZoom > 1.05)
            _ZoomButton(zoom: state.zoom, maxZoom: state.maxZoom),
          _SlimButton(
            icon: Icons.camera_alt_outlined,
            tooltip: 'Camera settings',
            active: cameraSettingsActive,
            onPressed: onCameraSettingsPressed,
          ),
          const SizedBox(width: 6),
          _GoLiveButton(onGoLive: onGoLive),
        ],
      ),
    );
  }
}

class _SlimButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;
  final Color activeColor;
  const _SlimButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
    this.activeColor = ControlRoomColors.amber,
  });

  @override
  Widget build(BuildContext context) {
    final scale = (MediaQuery.sizeOf(context).shortestSide / 400).clamp(0.8, 1.6);
    final iconSize = (20 * scale).roundToDouble();
    return Container(
      decoration: BoxDecoration(
        color: active ? activeColor.withValues(alpha: 0.2) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: iconSize),
        color: active ? activeColor : ControlRoomColors.textPrimary,
        padding: EdgeInsets.all(6 * scale),
        constraints: BoxConstraints(minWidth: 32 * scale, minHeight: 32 * scale),
        splashRadius: (16 * scale).roundToDouble(),
      ),
    );
  }
}

class _GoLiveButton extends ConsumerWidget {
  const _GoLiveButton({required this.onGoLive});

  final VoidCallback onGoLive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(broadcastControllerProvider);
    final controller = ref.read(broadcastControllerProvider.notifier);

    if (state.isLive || state.isBusy) {
      // Long-press guard so a stray tap can't kill a live broadcast.
      return GestureDetector(
        onLongPress: controller.stop,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: ControlRoomColors.tallyRed,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'HOLD STOP',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.8),
          ),
        ),
      );
    }

    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: ControlRoomColors.tallyRed,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: state.initialized ? onGoLive : null,
      child: const Text(
        'GO LIVE',
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 0.8),
      ),
    );
  }
}

class ZoomPills extends ConsumerWidget {
  const ZoomPills({super.key});

  void _showSlider(BuildContext context, WidgetRef ref) {
    final state = ref.read(broadcastControllerProvider);
    final ctrl = ref.read(broadcastControllerProvider.notifier);
    var currentZoom = state.zoom;
    final effectiveMax = state.maxZoom;
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 160),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 260,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Zoom: ${currentZoom.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 11)),
                    const SizedBox(height: 6),
                    Slider(
                      value: currentZoom.clamp(0.5, effectiveMax),
                      min: 0.5,
                      max: effectiveMax,
                      activeColor: ControlRoomColors.amber,
                      onChanged: (v) {
                        currentZoom = v;
                        setDialogState(() {});
                        ctrl.setZoom(v);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capsAsync = ref.watch(cameraCapabilitiesFutureProvider);
    final state = ref.watch(broadcastControllerProvider);
    final ctrl = ref.read(broadcastControllerProvider.notifier);

    return capsAsync.when(
      data: (caps) {
        final minZoom = (caps['minZoom'] as num?)?.toDouble() ?? 1.0;
        final switchOverPoints = (caps['switchOverPoints'] as List<dynamic>?)?.cast<double>() ?? <double>[];
        final levels = <double>[0.5, 1.0, ...switchOverPoints, 2.0];
        final unique = levels.toSet().toList()..sort();

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: unique.map((level) {
            final active = (state.zoom - level).abs() < 0.05;
            return GestureDetector(
              onTap: () => ctrl.setZoom(level),
              onLongPress: () => _showSlider(context, ref),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: active ? ControlRoomColors.amber.withValues(alpha: 0.3) : Colors.white12,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${level == level.truncateToDouble() ? level.toInt() : level}x',
                  style: TextStyle(
                    color: active ? ControlRoomColors.amber : Colors.white70,
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _ZoomButton extends ConsumerWidget {
  final double zoom;
  final double maxZoom;
  const _ZoomButton({required this.zoom, required this.maxZoom});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(broadcastControllerProvider.notifier);
    final effectiveMax = maxZoom.clamp(1.0, 20.0);
    return GestureDetector(
      onTap: () {
        var currentZoom = zoom;
        showDialog(
          context: context,
          barrierColor: Colors.transparent,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 72),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: 260,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Zoom: ${currentZoom.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 11)),
                        const SizedBox(height: 6),
                        Slider(
                          value: currentZoom.clamp(0.5, effectiveMax),
                          min: 0.5,
                          max: effectiveMax,
                          activeColor: ControlRoomColors.amber,
                          onChanged: (v) {
                            currentZoom = v;
                            setDialogState(() {});
                            ctrl.setZoom(v);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: zoom > 1.0 ? ControlRoomColors.amber.withValues(alpha: 0.2) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: IconButton(
          tooltip: 'Zoom',
          onPressed: null,
          icon: Icon(Icons.zoom_in, size: 20),
          color: zoom > 1.0 ? ControlRoomColors.amber : ControlRoomColors.textPrimary,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          splashRadius: 16,
        ),
      ),
    );
  }
}

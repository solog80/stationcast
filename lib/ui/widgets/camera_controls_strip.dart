import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../broadcast/providers.dart';
import '../../models/camera_settings.dart';
import '../../theme/control_room_theme.dart';

enum _ControlType { wb, iso, ev, focus, flash, eis }

class CameraControlsStrip extends ConsumerStatefulWidget {
  const CameraControlsStrip({super.key});

  @override
  ConsumerState<CameraControlsStrip> createState() =>
      _CameraControlsStripState();
}

class _CameraControlsStripState extends ConsumerState<CameraControlsStrip> {
  _ControlType? _expanded;

  @override
  Widget build(BuildContext context) {
    final cameraAsync = ref.watch(cameraSettingsProvider);
    return cameraAsync.when(
      data: (camera) => _build(camera),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _build(CameraSettings camera) {
    final items = [
      _ControlItem(
        type: _ControlType.wb,
        icon: Icons.light_mode,
        label: _wbLabel(camera.whiteBalance),
        active: camera.whiteBalance != WhiteBalanceMode.auto,
      ),
      _ControlItem(
        type: _ControlType.iso,
        icon: Icons.invert_colors,
        label: 'ISO${camera.isoSensitivity}',
        active: camera.isoSensitivity != 100,
      ),
      _ControlItem(
        type: _ControlType.ev,
        icon: Icons.exposure,
        label:
            'EV${camera.exposureCompensation >= 0 ? '+' : ''}${camera.exposureCompensation}',
        active: camera.exposureCompensation != 0,
      ),
      _ControlItem(
        type: _ControlType.focus,
        icon: Icons.center_focus_strong,
        label: _focusLabel(camera.focusMode),
        active: camera.focusMode != FocusMode.auto,
      ),
      _ControlItem(
        type: _ControlType.flash,
        icon: camera.flashMode == FlashMode.torch
            ? Icons.flashlight_on
            : Icons.flashlight_off,
        label: camera.flashMode == FlashMode.torch ? 'TORCH' : 'OFF',
        active: camera.flashMode == FlashMode.torch,
        isToggle: true,
      ),
      _ControlItem(
        type: _ControlType.eis,
        icon: camera.videoStabilization
            ? Icons.videocam
            : Icons.videocam_outlined,
        label: 'EIS',
        active: camera.videoStabilization,
        isToggle: true,
      ),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Side panel when expanded
        if (_expanded != null)
          _buildPanel(camera, items.firstWhere((i) => i.type == _expanded!)),
        // Main strip
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: items.map((item) => _buildIcon(camera, item)).toList(),
          ),
        ),
      ],
    );
  }

  void _handleTap(CameraSettings camera, _ControlItem item) {
    HapticFeedback.lightImpact();
    if (item.isToggle) {
      final notifier = ref.read(cameraSettingsProvider.notifier);
      if (item.type == _ControlType.flash) {
        notifier.save(
          camera.copyWith(
            flashMode: camera.flashMode == FlashMode.torch
                ? FlashMode.off
                : FlashMode.torch,
          ),
        );
      } else if (item.type == _ControlType.eis) {
        notifier.save(
          camera.copyWith(videoStabilization: !camera.videoStabilization),
        );
      }
    } else {
      setState(() => _expanded = _expanded == item.type ? null : item.type);
    }
  }

  Widget _buildIcon(CameraSettings camera, _ControlItem item) {
    final isExpanded = _expanded == item.type;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        onTap: () => _handleTap(camera, item),
        child: Container(
          width: 48,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isExpanded
                ? ControlRoomColors.amber.withValues(alpha: 0.3)
                : item.active
                ? ControlRoomColors.amber.withValues(alpha: 0.15)
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Icon(
                item.icon,
                size: 22,
                color: isExpanded || item.active
                    ? ControlRoomColors.amber
                    : Colors.white54,
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 8,
                  color: isExpanded || item.active
                      ? ControlRoomColors.amber
                      : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(CameraSettings camera, _ControlItem item) {
    return Container(
      width: 56,
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _panelOptions(camera, item.type),
        ),
      ),
    );
  }

  List<Widget> _panelOptions(CameraSettings camera, _ControlType type) {
    final notifier = ref.read(cameraSettingsProvider.notifier);
    switch (type) {
      case _ControlType.wb:
        return WhiteBalanceMode.values
            .map(
              (m) => _panelOption(
                icon: _wbIcon(m),
                tooltip: m.name,
                selected: camera.whiteBalance == m,
                onTap: () {
                  notifier.save(camera.copyWith(whiteBalance: m));
                  setState(() => _expanded = null);
                },
              ),
            )
            .toList();
      case _ControlType.iso:
        return [100, 200, 400, 800, 1600, 3200]
            .map(
              (v) => _numOption(
                label: '$v',
                selected: camera.isoSensitivity == v,
                onTap: () {
                  notifier.save(camera.copyWith(isoSensitivity: v));
                  setState(() => _expanded = null);
                },
              ),
            )
            .toList();
      case _ControlType.ev:
        return [-4, -3, -2, -1, 0, 1, 2, 3, 4]
            .map(
              (v) => _numOption(
                label: v >= 0 ? '+$v' : '$v',
                selected: camera.exposureCompensation == v,
                onTap: () {
                  notifier.save(camera.copyWith(exposureCompensation: v));
                  setState(() => _expanded = null);
                },
              ),
            )
            .toList();
      case _ControlType.focus:
        return FocusMode.values
            .map(
              (m) => _panelOption(
                icon: _focusIcon(m),
                tooltip: m.name,
                selected: camera.focusMode == m,
                onTap: () {
                  notifier.save(camera.copyWith(focusMode: m));
                  setState(() => _expanded = null);
                },
              ),
            )
            .toList();
      case _ControlType.flash:
        return [
          _panelOption(
            icon: Icons.flashlight_off,
            tooltip: 'Off',
            selected: camera.flashMode == FlashMode.off,
            onTap: () {
              notifier.save(camera.copyWith(flashMode: FlashMode.off));
              setState(() => _expanded = null);
            },
          ),
          _panelOption(
            icon: Icons.flashlight_on,
            tooltip: 'Torch',
            selected: camera.flashMode == FlashMode.torch,
            onTap: () {
              notifier.save(camera.copyWith(flashMode: FlashMode.torch));
              setState(() => _expanded = null);
            },
          ),
        ];
      case _ControlType.eis:
        return [
          _panelOption(
            icon: Icons.videocam,
            tooltip: 'On',
            selected: camera.videoStabilization,
            onTap: () {
              notifier.save(camera.copyWith(videoStabilization: true));
              setState(() => _expanded = null);
            },
          ),
          _panelOption(
            icon: Icons.videocam_outlined,
            tooltip: 'Off',
            selected: !camera.videoStabilization,
            onTap: () {
              notifier.save(camera.copyWith(videoStabilization: false));
              setState(() => _expanded = null);
            },
          ),
        ];
    }
  }
}

Widget _numOption({
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 44,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? ControlRoomColors.amber.withValues(alpha: 0.3)
              : null,
          borderRadius: BorderRadius.circular(6),
          border: selected
              ? Border.all(color: ControlRoomColors.amber, width: 1.5)
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? ControlRoomColors.amber : Colors.white54,
          ),
        ),
      ),
    ),
  );
}

Widget _panelOption({
  required IconData icon,
  required String tooltip,
  required bool selected,
  required VoidCallback onTap,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: selected
              ? ControlRoomColors.amber.withValues(alpha: 0.3)
              : null,
          borderRadius: BorderRadius.circular(8),
          border: selected
              ? Border.all(color: ControlRoomColors.amber, width: 1.5)
              : null,
        ),
        child: Tooltip(
          message: tooltip,
          child: Icon(
            icon,
            size: 24,
            color: selected ? ControlRoomColors.amber : Colors.white54,
          ),
        ),
      ),
    ),
  );
}

IconData _wbIcon(WhiteBalanceMode m) => switch (m) {
  WhiteBalanceMode.auto => Icons.tune,
  WhiteBalanceMode.daylight => Icons.wb_sunny,
  WhiteBalanceMode.cloudyDaylight => Icons.cloud,
  WhiteBalanceMode.fluorescent => Icons.fluorescent,
  WhiteBalanceMode.incandescent => Icons.lightbulb,
  WhiteBalanceMode.shade => Icons.shield,
  WhiteBalanceMode.twilight => Icons.nights_stay,
  WhiteBalanceMode.warmFluorescent => Icons.wb_iridescent,
};

IconData _focusIcon(FocusMode m) => switch (m) {
  FocusMode.auto => Icons.center_focus_strong,
  FocusMode.continuous => Icons.gps_fixed,
  FocusMode.manual => Icons.touch_app,
  FocusMode.macro => Icons.macro_off,
  FocusMode.infinity => Icons.landscape,
};

String _wbLabel(WhiteBalanceMode m) => switch (m) {
  WhiteBalanceMode.auto => 'AWB',
  WhiteBalanceMode.daylight => 'DAY',
  WhiteBalanceMode.cloudyDaylight => 'CLD',
  WhiteBalanceMode.fluorescent => 'FLR',
  WhiteBalanceMode.incandescent => 'INC',
  WhiteBalanceMode.shade => 'SHD',
  WhiteBalanceMode.twilight => 'TWI',
  WhiteBalanceMode.warmFluorescent => 'WFL',
};

String _focusLabel(FocusMode m) => switch (m) {
  FocusMode.auto => 'AF',
  FocusMode.continuous => 'AFC',
  FocusMode.manual => 'MF',
  FocusMode.macro => 'MAC',
  FocusMode.infinity => 'INF',
};

class _ControlItem {
  final _ControlType type;
  final IconData icon;
  final String label;
  final bool active;
  final bool isToggle;
  const _ControlItem({
    required this.type,
    required this.icon,
    required this.label,
    required this.active,
    this.isToggle = false,
  });
}

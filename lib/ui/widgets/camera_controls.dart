import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../broadcast/providers.dart';
import '../../models/camera_settings.dart';
import '../../theme/control_room_theme.dart';

/// Full manual camera control panel with all Camera2 features.
class CameraControlsSection extends ConsumerWidget {
  const CameraControlsSection({super.key, required this.camera});

  final CameraSettings camera;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(cameraSettingsProvider.notifier);

    return Card(
      color: ControlRoomColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Camera Controls',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            _FocusControlsSection(camera, notifier),
            const SizedBox(height: 16),
            _ExposureControlsSection(camera, notifier),
            const SizedBox(height: 16),
            _WhiteBalanceControlsSection(camera, notifier),
            const SizedBox(height: 16),
            _SensorControlsSection(camera, notifier),
            const SizedBox(height: 16),
            _StabilizationControlsSection(camera, notifier),
          ],
        ),
      ),
    );
  }
}

class _FocusControlsSection extends StatelessWidget {
  const _FocusControlsSection(this.camera, this.notifier);

  final CameraSettings camera;
  final CameraSettingsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return _ExpandableSection(
      title: 'Focus',
      children: [
        _SegmentedControl(
          label: 'Focus Mode',
          value: camera.focusMode,
          items: FocusMode.values,
          onChanged: (mode) =>
              notifier.save(camera.copyWith(focusMode: mode)),
        ),
      ],
    );
  }
}

class _ExposureControlsSection extends StatelessWidget {
  const _ExposureControlsSection(this.camera, this.notifier);

  final CameraSettings camera;
  final CameraSettingsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return _ExpandableSection(
      title: 'Exposure',
      children: [
        _SliderControl(
          label: 'EV Compensation',
          value: camera.exposureCompensation.toDouble(),
          min: -4,
          max: 4,
          divisions: 8,
          onChanged: (v) => notifier.save(
            camera.copyWith(exposureCompensation: v.round()),
          ),
        ),
      ],
    );
  }
}

class _WhiteBalanceControlsSection extends StatelessWidget {
  const _WhiteBalanceControlsSection(this.camera, this.notifier);

  final CameraSettings camera;
  final CameraSettingsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return _ExpandableSection(
      title: 'White Balance',
      children: [
        _SegmentedControl(
          label: 'Mode',
          value: camera.whiteBalance,
          items: WhiteBalanceMode.values,
          onChanged: (mode) =>
              notifier.save(camera.copyWith(whiteBalance: mode)),
        ),
      ],
    );
  }
}

class _SensorControlsSection extends StatelessWidget {
  const _SensorControlsSection(this.camera, this.notifier);

  final CameraSettings camera;
  final CameraSettingsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return _ExpandableSection(
      title: 'Sensor',
      children: [
        _SliderControl(
          label: 'Zoom',
          value: camera.zoom,
          min: 1.0,
          max: 8.0,
          divisions: 70,
          onChanged: (v) => notifier.save(camera.copyWith(zoom: v)),
        ),
        const SizedBox(height: 12),
        _SliderControl(
          label: 'ISO',
          value: camera.isoSensitivity.toDouble(),
          min: 100,
          max: 3200,
          divisions: 31,
          onChanged: (v) => notifier.save(
            camera.copyWith(isoSensitivity: v.round()),
          ),
        ),
      ],
    );
  }
}

class _StabilizationControlsSection extends StatelessWidget {
  const _StabilizationControlsSection(this.camera, this.notifier);

  final CameraSettings camera;
  final CameraSettingsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return _ExpandableSection(
      title: 'Stabilization & Effects',
      children: [
        _SwitchControl(
          label: 'Video Stabilization',
          value: camera.videoStabilization,
          onChanged: (v) =>
              notifier.save(camera.copyWith(videoStabilization: v)),
        ),
        const SizedBox(height: 12),
        _SegmentedControl(
          label: 'Flash Mode',
          value: camera.flashMode,
          items: FlashMode.values,
          onChanged: (mode) =>
              notifier.save(camera.copyWith(flashMode: mode)),
        ),
      ],
    );
  }
}

class _ExpandableSection extends StatefulWidget {
  const _ExpandableSection({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  State<_ExpandableSection> createState() => _ExpandableSectionState();
}

class _ExpandableSectionState extends State<_ExpandableSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ControlRoomColors.textPrimary,
                ),
              ),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: ControlRoomColors.textSecondary,
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 12),
          ...widget.children,
        ],
      ],
    );
  }
}

class _SliderControl extends StatelessWidget {
  const _SliderControl({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ${value.toStringAsFixed(1)}',
          style: const TextStyle(fontSize: 12, color: ControlRoomColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _SwitchControl extends StatelessWidget {
  const _SwitchControl({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _SegmentedControl<T> extends StatelessWidget {
  const _SegmentedControl({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<T>(
            selected: {value},
            onSelectionChanged: (selection) =>
                onChanged(selection.first),
            segments: items
                .map((item) => ButtonSegment(
                  value: item,
                  label: Text(_formatLabel(item.toString())),
                ))
                .toList(),
          ),
        ),
      ],
    );
  }

  String _formatLabel(String value) {
    return value.split('.').last;
  }
}
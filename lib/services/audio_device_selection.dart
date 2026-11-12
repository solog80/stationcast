import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../broadcast/providers.dart';

/// The microphone selected by the operator. Shared by TV, Radio, and Settings
/// so switching pages cannot silently reset the input to built-in.
final selectedAudioDeviceIdProvider = StateProvider<String?>((ref) => null);

final audioDeviceWatcherProvider = Provider<AudioDeviceWatcher>((ref) {
  final watcher = AudioDeviceWatcher(ref);
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// Keeps the preferred microphone in sync with hot-plugged USB/wired devices.
///
/// USB has priority over wired and built-in. A manually chosen device is kept
/// until a new USB device appears or the selected device disappears.
class AudioDeviceWatcher {
  AudioDeviceWatcher(this._ref);

  final ProviderRef<AudioDeviceWatcher> _ref;
  Timer? _timer;
  bool _refreshing = false;
  bool _disposed = false;
  Set<String> _knownUsbIds = <String>{};
  Future<void>? _startFuture;

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    await refresh();
    if (_disposed) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(refresh());
    });
  }

  BroadcastAudioDevice? _preferredDevice(
    List<BroadcastAudioDevice> devices,
  ) {
    for (final type in const ['usb', 'wired', 'builtin']) {
      for (final device in devices) {
        if (device.type == type) return device;
      }
    }
    return devices.isNotEmpty ? devices.first : null;
  }

  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    try {
      final controller = _ref.read(broadcastControllerProvider.notifier);
      final devices = await controller.getAudioDevices();
      if (_disposed) return;

      final usbIds = devices
          .where((device) => device.type == 'usb')
          .map((device) => device.id)
          .toSet();
      final newlyPluggedUsb = usbIds.difference(_knownUsbIds);
      _knownUsbIds = usbIds;

      final current = _ref.read(selectedAudioDeviceIdProvider);
      final currentPresent =
          current != null && devices.any((device) => device.id == current);

      BroadcastAudioDevice? next;
      if (newlyPluggedUsb.isNotEmpty) {
        next = devices.firstWhere(
          (device) => device.id == newlyPluggedUsb.first,
        );
      } else if (current == null || !currentPresent) {
        next = _preferredDevice(devices);
      }

      if (next != null && next.id != current) {
        _ref.read(selectedAudioDeviceIdProvider.notifier).state = next.id;
        await controller.selectAudioDevice(next.id);
      }
    } catch (_) {
      // Device enumeration can fail while a USB device is being removed.
    } finally {
      _refreshing = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

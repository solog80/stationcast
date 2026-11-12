import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../radio/providers.dart';
import '../services/audio_device_selection.dart';
import 'broadcast_screen.dart';
import 'radio_screen.dart';

enum AppMode { tv, radio }

const _lastModeKey = 'stationcast_last_mode';

/// Mode switch between the TV/SRT broadcast page and the Radio/SIP page.
///
/// The selected page owns the whole screen and exposes a small mode toggle in
/// its own chrome (passed as a callback). Switching away disposes the other
/// page so the native engines (camera/mic owned exclusively) are released.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  AppMode _mode = AppMode.tv;
  bool _modeLoaded = false;
  late final AudioDeviceWatcher _audioWatcher;

  @override
  void initState() {
    super.initState();
    _audioWatcher = ref.read(audioDeviceWatcherProvider);
    _restoreMode();
  }

  Future<void> _restoreMode() async {
    var mode = AppMode.tv;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_lastModeKey) == AppMode.radio.name) {
        mode = AppMode.radio;
      }
    } catch (_) {}

    // Select USB before the TV or Radio engine starts, then keep watching for
    // hot-plug/unplug while either page is open.
    await _audioWatcher.start();

    if (!mounted) return;
    setState(() {
      _mode = mode;
      _modeLoaded = true;
    });
  }

  Future<void> _persistMode(AppMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastModeKey, mode.name);
  }

  @override
  Widget build(BuildContext context) {
    if (!_modeLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return switch (_mode) {
      AppMode.tv => BroadcastScreen(
        onSwitchToRadio: () => _setMode(AppMode.radio),
      ),
      AppMode.radio => RadioScreen(
        onSwitchToTv: () => unawaited(_switchToTv()),
      ),
    };
  }

  void _setMode(AppMode mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    unawaited(_persistMode(mode));
  }

  Future<void> _switchToTv() async {
    await ref.read(radioControllerProvider.notifier).shutdown();
    if (!mounted) return;
    _setMode(AppMode.tv);
  }
}

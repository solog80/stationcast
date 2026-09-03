import 'package:flutter/material.dart';

import 'broadcast_screen.dart';
import 'radio_screen.dart';

enum AppMode { tv, radio }

/// Mode switch between the TV/SRT broadcast page and the Radio/SIP page.
///
/// The selected page owns the whole screen and exposes a small mode toggle in
/// its own chrome (passed as a callback). Switching away disposes the other
/// page so the native engines (camera/mic owned exclusively) are released.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppMode _mode = AppMode.tv;

  @override
  Widget build(BuildContext context) {
    return switch (_mode) {
      AppMode.tv => BroadcastScreen(onSwitchToRadio: () => _setMode(AppMode.radio)),
      AppMode.radio => RadioScreen(onSwitchToTv: () => _setMode(AppMode.tv)),
    };
  }

  void _setMode(AppMode mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
  }
}

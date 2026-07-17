import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/auth_service.dart';
import 'services/broadcast_reporter.dart';
import 'theme/control_room_theme.dart';
import 'ui/broadcast_screen.dart';
import 'ui/login_screen.dart';
import 'ui/onboarding/onboarding_screen.dart';

const _onboardingKey = 'stationcast_onboarding_complete';

class StationCastApp extends ConsumerStatefulWidget {
  const StationCastApp({super.key});

  @override
  ConsumerState<StationCastApp> createState() => _StationCastAppState();
}

class _StationCastAppState extends ConsumerState<StationCastApp> {
  User? _user;
  bool? _onboardingComplete;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    final auth = ref.read(authServiceProvider);
    ref.read(broadcastReporterProvider).ensureInit();
    auth.authStateChanges.listen((user) {
      if (mounted) setState(() => _user = user);
    });
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final complete = prefs.getBool(_onboardingKey) ?? false;
    if (mounted) setState(() => _onboardingComplete = complete);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StationCast',
      debugShowCheckedModeBanner: false,
      theme: buildControlRoomTheme(),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_onboardingComplete == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!_onboardingComplete!) return OnboardingScreen(onComplete: () => setState(() => _onboardingComplete = true));
    return _user != null ? const BroadcastScreen() : const LoginScreen();
  }
}

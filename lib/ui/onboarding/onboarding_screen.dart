import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/control_room_theme.dart';

const _onboardingKey = 'stationcast_onboarding_complete';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  late final PageController _pageCtrl;
  late final AnimationController _animCtrl;
  int _page = 0;
  bool _permissionsGranted = false;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    final statuses = await [Permission.camera, Permission.microphone].request();
    final micStatus = await Permission.microphone.status;
    // Also request notification permissions for background alerts
    await Permission.notification.request();
    if (mounted) {
      setState(() {
        _permissionsGranted =
            statuses[Permission.camera]?.isGranted == true &&
            micStatus.isGranted;
      });
    }
  }

  Future<void> _complete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey, true);
    widget.onComplete();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Skip button
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _complete,
                child: const Text('Skip', style: TextStyle(color: Colors.white38)),
              ),
            ),
            // Slides
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                onPageChanged: (p) => setState(() => _page = p),
                children: [
                  _Slide(
                    icon: Icons.settings_input_antenna,
                    title: 'Connect',
                    subtitle: 'Enter your station\'s SRT server URL or scan\na QR code from your admin dashboard.',
                    animCtrl: _animCtrl,
                    page: 0,
                    currentPage: _page,
                  ),
                  _Slide(
                    icon: Icons.tune,
                    title: 'Configure',
                    subtitle: 'Set your encoder preset — balance\nquality vs latency for your network.\nChoose keyframe interval and bitrate.',
                    animCtrl: _animCtrl,
                    page: 1,
                    currentPage: _page,
                  ),
                  _Slide(
                    icon: Icons.fiber_manual_record,
                    title: 'Go Live',
                    subtitle: 'Tap the red button to start streaming.\nMonitor bitrate, RTT, and dropped packets.\nReceive your return feed in the PiP window.',
                    animCtrl: _animCtrl,
                    page: 2,
                    currentPage: _page,
                  ),
                ],
              ),
            ),
            // Permissions status
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  _permissionDot('Camera', _permissionsGranted),
                  const SizedBox(width: 16),
                  _permissionDot('Microphone', _permissionsGranted),
                  const SizedBox(width: 16),
                  _permissionDot('Notifications', _permissionsGranted),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Page dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: _page == i ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _page == i ? ControlRoomColors.amber : Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              )),
            ),
            const SizedBox(height: 32),
            // Continue button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ControlRoomColors.amber,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _page < 2
                      ? () => _pageCtrl.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut)
                      : _complete,
                  child: Text(
                    _page < 2 ? 'Next' : 'Start Broadcasting',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  Widget _permissionDot(String label, bool granted) {
    return Expanded(
      child: Row(
        children: [
          Icon(
            granted ? Icons.check_circle : Icons.circle_outlined,
            color: granted ? Colors.green : Colors.white24,
            size: 14,
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: Colors.white54, fontSize: 11)),
        ],
      ),
    );
  }
}

class _Slide extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final AnimationController animCtrl;
  final int page;
  final int currentPage;

  const _Slide({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.animCtrl,
    required this.page,
    required this.currentPage,
  });

  @override
  Widget build(BuildContext context) {
    final visible = currentPage == page;
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.3,
      duration: const Duration(milliseconds: 300),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: ControlRoomColors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(50),
              ),
              child: Icon(icon, color: ControlRoomColors.amber, size: 48),
            ),
            const SizedBox(height: 32),
            Text(
              title,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.white60,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tipsKey = 'stationcast_tips_shown';

class FirstLaunchTips extends StatefulWidget {
  final Widget child;
  const FirstLaunchTips({super.key, required this.child});

  @override
  State<FirstLaunchTips> createState() => _FirstLaunchTipsState();
}

class _FirstLaunchTipsState extends State<FirstLaunchTips>
    with SingleTickerProviderStateMixin {
  bool _showTips = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool(_tipsKey) ?? false;
    if (!shown && mounted) {
      setState(() => _showTips = true);
      await prefs.setBool(_tipsKey, true);
      Future.delayed(const Duration(seconds: 6), () {
        if (mounted) setState(() => _showTips = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_showTips)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Colors.black45,
                child: Column(
                  children: [
                    const Spacer(flex: 3),
                    _tip(Icons.touch_app, 'Tap to focus', alignment: Alignment.center),
                    const Spacer(),
                    _tip(Icons.swipe, 'Swipe to show/hide controls', alignment: Alignment.center),
                    const Spacer(),
                    _tip(Icons.timer, 'Long-press zoom pill for fine slider', alignment: Alignment.center),
                    const Spacer(flex: 4),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tip(IconData icon, String text, {Alignment alignment = Alignment.center}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.amberAccent, size: 20),
          const SizedBox(width: 10),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}

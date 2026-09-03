import 'package:flutter/material.dart';

import '../../theme/control_room_theme.dart';

class AudioMeter extends StatelessWidget {
  const AudioMeter({super.key, required this.levelsDb});

  final List<double> levelsDb;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: ControlRoomColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final level in levelsDb.take(2)) ...[
            _MeterBar(levelDb: level),
            const SizedBox(width: 3),
          ],
        ],
      ),
    );
  }
}

class _MeterBar extends StatelessWidget {
  const _MeterBar({required this.levelDb});
  final double levelDb;

  @override
  Widget build(BuildContext context) {
    final fraction = ((levelDb + 60) / 60).clamp(0.0, 1.0);
    return SizedBox(
      width: 8, height: 80,
      child: CustomPaint(painter: _MeterPainter(fraction)),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.fraction);
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()..color = ControlRoomColors.surfaceRaised;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(3)), track);
    final fillHeight = size.height * fraction;
    if (fillHeight <= 0) return;
    final rect = Rect.fromLTWH(0, size.height - fillHeight, size.width, fillHeight);
    final gradient = const LinearGradient(
      begin: Alignment.bottomCenter, end: Alignment.topCenter,
      colors: [ControlRoomColors.meterGreen, ControlRoomColors.meterGreen, ControlRoomColors.amber, ControlRoomColors.tallyRed],
      stops: [0.0, 0.6, 0.85, 1.0],
    ).createShader(Offset.zero & size);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), Paint()..shader = gradient);
  }

  @override
  bool shouldRepaint(_MeterPainter oldDelegate) => oldDelegate.fraction != fraction;
}

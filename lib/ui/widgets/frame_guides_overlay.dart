import 'package:flutter/material.dart';

class FrameGuidesOverlay extends StatelessWidget {
  const FrameGuidesOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SafeAreaPainter(),
      size: Size.infinite,
    );
  }
}

class _SafeAreaPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final rect = Rect.fromLTWH(
      w * 0.1, h * 0.1, w * 0.8, h * 0.8,
    );

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 0.5;

    canvas.drawRect(rect, outline);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

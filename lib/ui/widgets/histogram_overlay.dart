import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../broadcast/providers.dart';

class HistogramOverlay extends ConsumerStatefulWidget {
  const HistogramOverlay({super.key});

  @override
  ConsumerState<HistogramOverlay> createState() => _HistogramOverlayState();
}

class _HistogramOverlayState extends ConsumerState<HistogramOverlay> {
  List<int> _bins = List.filled(256, 0);
  Stream<List<int>>? _histogramStream;

  @override
  void initState() {
    super.initState();
    final plugin = ref.read(broadcastPluginProvider);
    _histogramStream = plugin.histogram;
    _histogramStream!.listen((bins) {
      if (mounted) setState(() => _bins = bins);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 140,
        height: 60,
        color: Colors.black.withValues(alpha: 0.35),
        child: CustomPaint(
          painter: _HistogramPainter(bins: _bins),
          size: const Size(140, 60),
        ),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  final List<int> bins;

  _HistogramPainter({required this.bins});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final binCount = bins.length;
    if (binCount == 0) return;
    final barWidth = w / binCount;

    // Split into thirds for RGB-like coloring: shadows, midtones, highlights
    final shadowPaint = Paint()..color = Colors.green.withValues(alpha: 0.5);
    final midPaint = Paint()..color = Colors.white.withValues(alpha: 0.6);
    final highlightPaint = Paint()..color = Colors.red.withValues(alpha: 0.5);

    for (var i = 0; i < binCount; i++) {
      final value = bins[i] / 100.0;
      final barHeight = value * h;
      final p = i < binCount ~/ 3
          ? shadowPaint
          : i < binCount * 2 ~/ 3
              ? midPaint
              : highlightPaint;
      canvas.drawLine(
        Offset(i * barWidth, h),
        Offset(i * barWidth, h - barHeight),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter oldDelegate) =>
      oldDelegate.bins != bins;
}

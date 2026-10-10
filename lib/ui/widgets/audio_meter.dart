import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../theme/control_room_theme.dart';

/// Professional broadcast audio ballistics (matching OpenPocketCine standard).
class AudioMeterBallistics {
  static const double floorDb = -60.0;
  static const double levelDecayPerSecond = 26.0;
  static const double peakHoldSeconds = 1.8;
  static const double peakDecayPerSecond = 12.0;

  static double decibelsFromLinear(double linear) {
    if (linear <= 0.0) return floorDb;
    return (20.0 * (math.log(linear) / math.ln10)).clamp(floorDb, 0.0);
  }
}

class AudioMeterChannelState {
  final double levelDb;
  final double peakDb;
  final double peakAge;

  const AudioMeterChannelState({
    this.levelDb = AudioMeterBallistics.floorDb,
    this.peakDb = AudioMeterBallistics.floorDb,
    this.peakAge = 0.0,
  });

  AudioMeterChannelState step(double incomingDb, double dt) {
    final stepDt = math.max(0.0, dt);
    final input = incomingDb.clamp(AudioMeterBallistics.floorDb, 0.0);

    // Instant attack, smooth exponential/linear decay
    final decayedLevel = math.max(
      AudioMeterBallistics.floorDb,
      levelDb - AudioMeterBallistics.levelDecayPerSecond * stepDt,
    );
    final nextLevel = math.max(input, decayedLevel);

    // Peak hold & peak decay
    double nextPeak;
    double nextAge;
    if (input >= peakDb) {
      nextPeak = input;
      nextAge = 0.0;
    } else {
      nextAge = peakAge + stepDt;
      if (nextAge > AudioMeterBallistics.peakHoldSeconds) {
        nextPeak = math.max(
          AudioMeterBallistics.floorDb,
          peakDb - AudioMeterBallistics.peakDecayPerSecond * stepDt,
        );
      } else {
        nextPeak = peakDb;
      }
    }

    return AudioMeterChannelState(
      levelDb: nextLevel,
      peakDb: math.max(nextPeak, nextLevel),
      peakAge: nextAge,
    );
  }
}

class AudioMeter extends StatefulWidget {
  const AudioMeter({
    super.key,
    required this.levelsDb,
    this.showLabels = true,
  });

  final List<double> levelsDb;
  final bool showLabels;

  @override
  State<AudioMeter> createState() => _AudioMeterState();
}

class _AudioMeterState extends State<AudioMeter> with SingleTickerProviderStateMixin {
  late AnimationController _ticker;
  DateTime _lastTime = DateTime.now();

  AudioMeterChannelState _leftChannel = const AudioMeterChannelState();
  AudioMeterChannelState _rightChannel = const AudioMeterChannelState();

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _ticker.addListener(_onFrame);
    _lastTime = DateTime.now();
  }

  @override
  void didUpdateWidget(AudioMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _onFrame();
  }

  void _onFrame() {
    final now = DateTime.now();
    final dt = now.difference(_lastTime).inMicroseconds / 1000000.0;
    _lastTime = now;

    if (dt <= 0) return;

    final inL = widget.levelsDb.isNotEmpty ? widget.levelsDb[0] : AudioMeterBallistics.floorDb;
    final inR = widget.levelsDb.length > 1 ? widget.levelsDb[1] : inL;

    final nextL = _leftChannel.step(inL, dt);
    final nextR = _rightChannel.step(inR, dt);

    if (nextL.levelDb != _leftChannel.levelDb ||
        nextL.peakDb != _leftChannel.peakDb ||
        nextR.levelDb != _rightChannel.levelDb ||
        nextR.peakDb != _rightChannel.peakDb) {
      setState(() {
        _leftChannel = nextL;
        _rightChannel = nextR;
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: ControlRoomColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MeterBar(
                channelState: _leftChannel,
                label: widget.showLabels ? 'L' : null,
              ),
              const SizedBox(width: 4),
              _MeterBar(
                channelState: _rightChannel,
                label: widget.showLabels ? 'R' : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MeterBar extends StatelessWidget {
  const _MeterBar({
    required this.channelState,
    this.label,
  });

  final AudioMeterChannelState channelState;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final levelFrac = ((channelState.levelDb - AudioMeterBallistics.floorDb) /
            (-AudioMeterBallistics.floorDb))
        .clamp(0.0, 1.0);
    final peakFrac = ((channelState.peakDb - AudioMeterBallistics.floorDb) /
            (-AudioMeterBallistics.floorDb))
        .clamp(0.0, 1.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 9,
          height: 72,
          child: CustomPaint(
            painter: _BroadcastMeterPainter(
              levelFraction: levelFrac,
              peakFraction: peakFrac,
              peakDb: channelState.peakDb,
            ),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 3),
          Text(
            label!,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ],
    );
  }
}

class _BroadcastMeterPainter extends CustomPainter {
  final double levelFraction;
  final double peakFraction;
  final double peakDb;

  _BroadcastMeterPainter({
    required this.levelFraction,
    required this.peakFraction,
    required this.peakDb,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trackPaint = Paint()..color = ControlRoomColors.surfaceRaised;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2)),
      trackPaint,
    );

    // Draw reference mark lines at -6 dB, -18 dB, -36 dB
    final markPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1.0;
    for (final markDb in [-6.0, -18.0, -36.0]) {
      final markFrac = (markDb - AudioMeterBallistics.floorDb) / (-AudioMeterBallistics.floorDb);
      final y = size.height * (1.0 - markFrac);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), markPaint);
    }

    // Fill level bar
    final fillH = size.height * levelFraction;
    if (fillH > 0) {
      final rect = Rect.fromLTWH(0, size.height - fillH, size.width, fillH);
      final gradient = const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          Color(0xFF56EB84), // Green < -18 dB
          Color(0xFF56EB84),
          Color(0xFFF5D052), // Yellow -18 to -6 dB
          Color(0xFFFF5C52), // Red >= -6 dB
        ],
        stops: [0.0, 0.70, 0.90, 1.0],
      ).createShader(Offset.zero & size);

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..shader = gradient,
      );
    }

    // Draw peak-hold indicator tick line (1.5dp thick)
    if (peakFraction > 0.01) {
      final peakY = size.height * (1.0 - peakFraction);
      final Color peakColor = peakDb >= -6.0
          ? const Color(0xFFFF5C52)
          : (peakDb >= -18.0 ? const Color(0xFFF5D052) : const Color(0xFF56EB84));

      final peakPaint = Paint()
        ..color = peakColor
        ..strokeWidth = 1.5;

      canvas.drawLine(
        Offset(0, peakY.clamp(0.0, size.height - 1.0)),
        Offset(size.width, peakY.clamp(0.0, size.height - 1.0)),
        peakPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_BroadcastMeterPainter oldDelegate) {
    return oldDelegate.levelFraction != levelFraction ||
        oldDelegate.peakFraction != peakFraction ||
        oldDelegate.peakDb != peakDb;
  }
}

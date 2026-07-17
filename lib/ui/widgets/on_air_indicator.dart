import 'dart:async';

import 'package:flutter/material.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../../theme/control_room_theme.dart';

class OnAirIndicator extends StatefulWidget {
  const OnAirIndicator({
    super.key,
    required this.connection,
    this.liveSince,
    this.reconnectAttempt = 0,
  });

  final BroadcastConnectionState connection;
  final DateTime? liveSince;
  final int reconnectAttempt;

  @override
  State<OnAirIndicator> createState() => _OnAirIndicatorState();
}

class _OnAirIndicatorState extends State<OnAirIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
      lowerBound: 0.35,
    )..repeat(reverse: true);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.liveSince != null && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (label, color, pulsing) = switch (widget.connection) {
      BroadcastConnectionState.live => (
        'LIVE',
        ControlRoomColors.tallyRed,
        false,
      ),
      BroadcastConnectionState.connecting => (
        'CONNECTING',
        ControlRoomColors.amber,
        true,
      ),
      BroadcastConnectionState.reconnecting => (
        'RECONNECT ${widget.reconnectAttempt}/3',
        ControlRoomColors.amber,
        true,
      ),
      BroadcastConnectionState.failed => (
        'FAILED',
        ControlRoomColors.tallyRed,
        false,
      ),
      _ => ('OFF', ControlRoomColors.textSecondary, false),
    };

    final elapsed = widget.liveSince == null
        ? null
        : DateTime.now().difference(widget.liveSince!);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: pulsing ? _pulse : const AlwaysStoppedAnimation(1),
            child: Icon(Icons.circle, size: 10, color: color),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (elapsed != null) ...[
            const SizedBox(width: 4),
            Text(
              _format(elapsed),
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  String _format(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }
}

import 'package:flutter/material.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../../theme/control_room_theme.dart';

/// Bitrate / RTT / drops chip row, color-coded green→amber→red.
class HealthOverlay extends StatelessWidget {
  const HealthOverlay({super.key, required this.stats});

  final StreamStats stats;

  @override
  Widget build(BuildContext context) {
    final mbps = stats.bitrateBps / 1_000_000;
    final bitrateColor = mbps >= 1.5
        ? ControlRoomColors.meterGreen
        : mbps >= 0.6
            ? ControlRoomColors.amber
            : ControlRoomColors.tallyRed;
    final rttColor = stats.rttMs < 120
        ? ControlRoomColors.meterGreen
        : stats.rttMs < 300
            ? ControlRoomColors.amber
            : ControlRoomColors.tallyRed;
    final dropColor = stats.packetsDropped == 0
        ? ControlRoomColors.meterGreen
        : ControlRoomColors.amber;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _chip('${mbps.toStringAsFixed(2)} Mb/s', bitrateColor),
        const SizedBox(width: 6),
        _chip('${stats.rttMs.toStringAsFixed(0)} ms', rttColor),
        const SizedBox(width: 6),
        _chip('drop ${stats.packetsDropped}', dropColor),
      ],
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: ControlRoomColors.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(text, style: statsTextStyle),
          ],
        ),
      );
}

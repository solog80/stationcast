import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../talkback/talkback_controller.dart';
import '../../theme/control_room_theme.dart';

class TalkbackIndicator extends ConsumerWidget {
  const TalkbackIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final talkback = ref.watch(talkbackControllerProvider);
    final active = talkback.active;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.mic,
            size: 10,
            color: active ? ControlRoomColors.amber : Colors.white38,
          ),
          const SizedBox(width: 4),
          Text(
            'TALK',
            style: TextStyle(
              color: active ? ControlRoomColors.amber : Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

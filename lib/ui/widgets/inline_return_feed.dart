import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../return_feed/return_feed_controller.dart';
import '../../return_feed/return_feed_player.dart';
import '../../theme/control_room_theme.dart';

class InlineReturnFeed extends ConsumerStatefulWidget {
  const InlineReturnFeed({super.key});

  @override
  ConsumerState<InlineReturnFeed> createState() => _InlineReturnFeedState();
}

class _InlineReturnFeedState extends ConsumerState<InlineReturnFeed> {
  bool _didAutoShow = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(returnFeedControllerProvider);

    if (state.playback == ReturnFeedState.idle && !_didAutoShow) {
      _didAutoShow = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(returnFeedControllerProvider.notifier).show();
      });
    }

    final player = ref.read(returnFeedControllerProvider.notifier).player;

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildContent(context, state, player),
        Positioned(
          top: 8,
          right: 8,
          child: _buildMiniControls(state, ref),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, ReturnFeedUiState state, dynamic player) {
    switch (state.playback) {
      case ReturnFeedState.idle:
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No return feed URL set',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: ControlRoomColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        );
      case ReturnFeedState.error:
        return Container(
          color: Colors.black,
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning, color: ControlRoomColors.tallyRed, size: 32),
                SizedBox(height: 8),
                Text(
                  'FEED LOST',
                  style: TextStyle(
                    color: ControlRoomColors.tallyRed,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        );
      case ReturnFeedState.buffering:
      case ReturnFeedState.playing:
        return Stack(
          fit: StackFit.expand,
          children: [
            if (player != null) player.buildVideo(context),
            if (state.playback == ReturnFeedState.buffering)
              const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
          ],
        );
    }
  }

  Widget _buildMiniControls(ReturnFeedUiState state, WidgetRef ref) {
    final controller = ref.read(returnFeedControllerProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(6),
          ),
          child: IconButton(
            icon: Icon(
              state.muted ? Icons.volume_off : Icons.volume_up,
              size: 18,
              color: state.muted ? ControlRoomColors.amber : Colors.white,
            ),
            onPressed: controller.toggleMute,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(width: 4),
        Container(
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(6),
          ),
          child: IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.white),
            onPressed: controller.hide,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

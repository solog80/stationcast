import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../return_feed/return_feed_controller.dart';
import '../../return_feed/return_feed_player.dart';
import '../../theme/control_room_theme.dart';
import '../../utils/log.dart';

/// Draggable, snap-to-corner floating window showing the station return feed.
/// 16:9 locked, muted by default (echo protection).
class FloatingReturnFeed extends ConsumerStatefulWidget {
  const FloatingReturnFeed({super.key});

  @override
  ConsumerState<FloatingReturnFeed> createState() => _FloatingReturnFeedState();
}

class _FloatingReturnFeedState extends ConsumerState<FloatingReturnFeed> {
  static const _margin = 12.0;
  static const _topBarHeight = 44.0;   // room for OnAir + indicators
  static const _portraitBottomBar = 100.0; // room for controls + metadata
  static const _landscapeBottomBar = 0.0;
  Offset _position = const Offset(_margin, _margin + _topBarHeight);
  double _width = 220;
  bool _showControls = false;
  Size _lastScreenSize = Size.zero;

  double _bottomBarHeight(Size screen) {
    return screen.width > screen.height ? _landscapeBottomBar : _portraitBottomBar;
  }

  void _constrainPosition(Size screen, EdgeInsets safe, double height) {
    final bottomBar = _bottomBarHeight(screen);
    _position = Offset(
      _position.dx.clamp(_margin, screen.width - _width - _margin),
      _position.dy.clamp(safe.top + _topBarHeight, screen.height - height - safe.bottom - bottomBar),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(returnFeedControllerProvider);
    if (!state.visible) return const SizedBox.shrink();

    final controller = ref.read(returnFeedControllerProvider.notifier);
    final height = _width * 9 / 16;
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final orientation = MediaQuery.of(context).orientation;
    final bottomBar = _bottomBarHeight(screen);

    log('[FloatingReturnFeed] build: ${screen.width}x${screen.height} ($orientation), pos=${_position.dx},${_position.dy}');

    // Re-constrain position if screen size changed (orientation changed)
    if (_lastScreenSize != screen) {
      log('[FloatingReturnFeed] Screen size changed from ${_lastScreenSize.width}x${_lastScreenSize.height} to ${screen.width}x${screen.height}');
      _lastScreenSize = screen;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          log('[FloatingReturnFeed] Re-constraining position');
          setState(() => _constrainPosition(screen, safe, height));
        }
      });
    }

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        onTap: () {
          log('[FloatingReturnFeed] tap: toggling controls');
          setState(() => _showControls = !_showControls);
        },
        onPanUpdate: (details) {
          setState(() {
            _position = Offset(
              (_position.dx + details.delta.dx)
                  .clamp(_margin, screen.width - _width - _margin),
              (_position.dy + details.delta.dy)
                  .clamp(safe.top + _topBarHeight, screen.height - height - safe.bottom - bottomBar),
            );
          });
        },
        onPanEnd: (_) {
          log('[FloatingReturnFeed] pan end: snapping to corner');
          _snapToCorner(screen, safe, height);
        },
        child: Container(
          width: _width,
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: state.playback == ReturnFeedState.error
                  ? ControlRoomColors.tallyRed
                  : ControlRoomColors.outline,
              width: 1.5,
            ),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4)),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildContent(state),
              // Always-visible mute overlay in top-right
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: controller.toggleMute,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      state.muted ? Icons.volume_off : Icons.volume_up,
                      color: state.muted ? ControlRoomColors.amber : Colors.white70,
                      size: 18,
                    ),
                  ),
                ),
              ),
              if (_showControls) _buildControls(state, controller),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(ReturnFeedUiState state) {
    log('[FloatingReturnFeed._buildContent] state=${state.playback}');
    final player = ref.read(returnFeedControllerProvider.notifier).player;
    switch (state.playback) {
      case ReturnFeedState.idle:
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'No return feed URL set',
              textAlign: TextAlign.center,
              style: TextStyle(color: ControlRoomColors.textSecondary, fontSize: 12),
            ),
          ),
        );
      case ReturnFeedState.error:
        return const Center(
          child: Text(
            'FEED LOST',
            style: TextStyle(
              color: ControlRoomColors.tallyRed,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      case ReturnFeedState.buffering:
        return Stack(
          fit: StackFit.expand,
          children: [
            if (player != null) player.buildVideo(context),
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
        );
      case ReturnFeedState.playing:
        return player?.buildVideo(context) ?? const SizedBox.shrink();
    }
  }

  Widget _buildControls(ReturnFeedUiState state, ReturnFeedController controller) {
    return Container(
      color: Colors.black45,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: Icon(
              state.muted ? Icons.volume_off : Icons.volume_up,
              color: state.muted ? ControlRoomColors.amber : Colors.white,
            ),
            onPressed: controller.toggleMute,
          ),
          IconButton(
            icon: Icon(
              _width < 300 ? Icons.open_in_full : Icons.close_fullscreen,
              color: Colors.white,
            ),
            onPressed: () => setState(() => _width = _width < 300 ? 340 : 220),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: controller.hide,
          ),
        ],
      ),
    );
  }

  void _snapToCorner(Size screen, EdgeInsets safe, double height) {
    final bottomBar = _bottomBarHeight(screen);
    final centerX = _position.dx + _width / 2;
    final centerY = _position.dy + height / 2;
    setState(() {
      _position = Offset(
        centerX < screen.width / 2 ? _margin : screen.width - _width - _margin,
        centerY < screen.height / 2
            ? safe.top + _topBarHeight
            : screen.height - height - safe.bottom - bottomBar,
      );
    });
  }
}

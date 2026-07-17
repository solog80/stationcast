import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

const String _viewType = 'tv.stationcast/srt_player';

class NativeSrtPlayer extends StatefulWidget {
  const NativeSrtPlayer({
    super.key,
    required this.url,
    this.muted = true,
  });

  final String url;
  final bool muted;

  @override
  State<NativeSrtPlayer> createState() => _NativeSrtPlayerState();
}

class _NativeSrtPlayerState extends State<NativeSrtPlayer> {
  int? _viewId;

  @override
  Widget build(BuildContext context) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return PlatformViewLink(
          viewType: _viewType,
          surfaceFactory: (context, controller) => AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          ),
          onCreatePlatformView: (params) {
            final controller = PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: _viewType,
              layoutDirection: TextDirection.ltr,
              creationParams: <String, dynamic>{'url': widget.url},
              creationParamsCodec: const StandardMessageCodec(),
            );
            controller.addOnPlatformViewCreatedListener((id) {
              _viewId = id;
              _sendVolume(id, widget.muted);
            });
            controller.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
            controller.create();
            return controller;
          },
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: _viewType,
          creationParams: <String, dynamic>{'url': widget.url},
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: (id) {
            _viewId = id;
            _sendVolume(id, widget.muted);
          },
        );
      default:
        return const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Text(
              'SRT player unsupported on this platform',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        );
    }
  }

  @override
  void didUpdateWidget(NativeSrtPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.muted != oldWidget.muted && _viewId != null) {
      _sendVolume(_viewId!, widget.muted);
    }
  }

  void _sendVolume(int viewId, bool muted) {
    MethodChannel('tv.stationcast/srt_player_$viewId')
        .invokeMethod('setVolume', {'volume': muted ? 0.0 : 1.0});
  }
}

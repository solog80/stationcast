import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

const String _viewType = 'tv.stationcast/camera_preview';

/// Camera preview rendered by the native streaming engine (StreamPack
/// PreviewView on Android, HaishinKit MTHKView on iOS).
///
/// The native engine owns the camera; this widget only displays its preview
/// surface. Call [StationBroadcast.initialize] before showing it.
class NativeCameraPreview extends StatelessWidget {
  const NativeCameraPreview({super.key});

  @override
  Widget build(BuildContext context) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // Hybrid composition: the preview is a SurfaceView and must sit
        // correctly under Flutter overlay widgets.
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
              creationParams: const <String, Object?>{},
              creationParamsCodec: const StandardMessageCodec(),
            );
            controller
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create();
            return controller;
          },
        );
      case TargetPlatform.iOS:
        return const UiKitView(
          viewType: _viewType,
          creationParams: <String, Object?>{},
          creationParamsCodec: StandardMessageCodec(),
        );
      default:
        return const ColoredBox(
          color: Colors.black,
          child: Center(child: Text('Camera preview unsupported on this platform')),
        );
    }
  }
}

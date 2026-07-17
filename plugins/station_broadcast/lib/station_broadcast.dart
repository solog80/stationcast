import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'src/broadcast_events.dart';
import 'src/models.dart';

export 'src/broadcast_events.dart';
export 'src/models.dart';
export 'src/native_camera_preview.dart';
export 'src/native_srt_player.dart';

/// Facade over the native SRT/RTMP broadcast engines
/// (StreamPack on Android, HaishinKit on iOS).
///
/// Lifecycle: [initialize] → preview shows → [startStream] / [stopStream]
/// (repeatable) → [dispose].
class StationBroadcast {
  StationBroadcast({
    @visibleForTesting MethodChannel? methodChannel,
    @visibleForTesting EventChannel? eventsChannel,
    @visibleForTesting EventChannel? statsChannel,
    @visibleForTesting EventChannel? histogramChannel,
  })  : _channel = methodChannel ?? const MethodChannel('tv.stationcast/broadcast'),
        _events = eventsChannel ?? const EventChannel('tv.stationcast/broadcast/events'),
        _stats = statsChannel ?? const EventChannel('tv.stationcast/broadcast/stats'),
        _histogram = histogramChannel ?? const EventChannel('tv.stationcast/broadcast/histogram');

  final MethodChannel _channel;
  final EventChannel _events;
  final EventChannel _stats;
  final EventChannel _histogram;

  Stream<BroadcastEvent>? _eventStream;
  Stream<StreamStats>? _statsStream;
  Stream<List<int>>? _histogramStream;

  /// State-change and error events. Broadcast stream; safe to listen multiple times.
  Stream<BroadcastEvent> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map((e) => BroadcastEvent.fromMap(e as Map<Object?, Object?>));

  /// ~1 Hz link statistics plus audio levels.
  Stream<StreamStats> get stats => _statsStream ??= _stats
      .receiveBroadcastStream()
      .map((e) => StreamStats.fromMap(e as Map<Object?, Object?>));

  /// ~15 fps luminance histogram (256 bins, 0-100 normalized).
  Stream<List<int>> get histogram => _histogramStream ??= _histogram
      .receiveBroadcastStream()
      .map((e) => (e as List<Object?>).cast<int>());

  /// Creates the native streamer, opens camera+mic and starts the preview
  /// pipeline. Camera/mic permissions must already be granted.
  Future<void> initialize(EncoderConfig config) =>
      _channel.invokeMethod('initialize', config.toMap());

  /// Connects to the destination and starts publishing.
  Future<void> startStream(DestinationConfig destination) =>
      _channel.invokeMethod('startStream', destination.toMap());

  Future<void> stopStream() => _channel.invokeMethod('stopStream');

  Future<void> switchCamera() => _channel.invokeMethod('switchCamera');

  Future<void> setTorch(bool enabled) =>
      _channel.invokeMethod('setTorch', {'enabled': enabled});

  /// [ratio] is a zoom ratio, 1.0 = no zoom. Clamped natively to device range.
  Future<void> setZoom(double ratio) => _channel.invokeMethod('setZoom', {'ratio': ratio});

  Future<void> setMuted(bool muted) => _channel.invokeMethod('setMuted', {'muted': muted});

  /// Changes the video bitrate while streaming (manual adjust / adaptive hook).
  Future<void> setVideoBitrate(int bps) =>
      _channel.invokeMethod('setVideoBitrate', {'bps': bps});

  Future<List<BroadcastAudioDevice>> getAudioDevices() async {
    final result = await _channel.invokeMethod<List<Object?>>('getAudioDevices');
    return (result ?? const [])
        .map((e) => BroadcastAudioDevice.fromMap(e as Map<Object?, Object?>))
        .toList();
  }

  Future<void> selectAudioDevice(String id) =>
      _channel.invokeMethod('selectAudioDevice', {'id': id});

  /// Max camera zoom ratio for the active camera (1.0 if unknown).
  Future<double> getMaxZoom() async =>
      (await _channel.invokeMethod<num>('getMaxZoom'))?.toDouble() ?? 1.0;

  /// Gets the actual camera resolution and aspect ratio.
  Future<Map<dynamic, dynamic>?> getCameraResolution() =>
      _channel.invokeMethod<Map<dynamic, dynamic>>('getCameraResolution');

  /// Releases camera, mic and network resources.
  Future<void> dispose() => _channel.invokeMethod('dispose');

  /// Starts the talkback audio intercom.
  Future<void> talkbackStart(String url) =>
      _channel.invokeMethod('talkbackStart', {'url': url});

  /// Stops the talkback audio intercom.
  Future<void> talkbackStop() => _channel.invokeMethod('talkbackStop');

  /// Pauses the camera preview to save power (app went to background).
  Future<void> pausePreview() => _channel.invokeMethod('pausePreview');

  /// Resumes the camera preview (app returned to foreground).
  Future<void> resumePreview() => _channel.invokeMethod('resumePreview');

  /// Captures a JPEG frame from the camera. Returns bytes or null.
  Future<Uint8List?> takeSnapshot() =>
      _channel.invokeMethod<Uint8List>('takeSnapshot');

  /// Mirrors/flips the front camera output.
  Future<void> setMirrorFrontCamera(bool enabled) =>
      _channel.invokeMethod('setMirrorFrontCamera', {'enabled': enabled});

  // Camera2 direct control methods
  /// Initialize Camera2Manager for direct camera control.
  Future<void> camera2InitializeManager() =>
      _channel.invokeMethod('camera2InitializeManager');

  /// Set camera zoom ratio (1.0 = no zoom).
  Future<void> camera2SetZoom(double ratio) =>
      _channel.invokeMethod('camera2SetZoom', {'ratio': ratio});

  /// Set focus mode (auto, continuous, manual, macro, infinity).
  Future<void> camera2SetFocusMode(String mode) =>
      _channel.invokeMethod('camera2SetFocusMode', {'mode': mode});

  /// Set exposure compensation (-4 to +4 EV typically).
  Future<void> camera2SetExposureCompensation(int ev) =>
      _channel.invokeMethod('camera2SetExposureCompensation', {'ev': ev});

  /// Set white balance mode.
  Future<void> camera2SetWhiteBalance(String mode) =>
      _channel.invokeMethod('camera2SetWhiteBalance', {'mode': mode});

  /// Set ISO sensitivity value.
  Future<void> camera2SetIsoSensitivity(int iso) =>
      _channel.invokeMethod('camera2SetIsoSensitivity', {'iso': iso});

  /// Enable/disable video stabilization.
  Future<void> camera2SetVideoStabilization(bool enabled) =>
      _channel.invokeMethod('camera2SetVideoStabilization', {'enabled': enabled});

  /// Set flash mode (off, on, auto, torch).
  Future<void> camera2SetFlashMode(String mode) =>
      _channel.invokeMethod('camera2SetFlashMode', {'mode': mode});

  /// Apply all camera settings in a single native call to avoid flash reset.
  Future<void> applyAllCameraSettings({
    required String whiteBalance,
    required int exposure,
    required String focus,
    required int iso,
    required String flash,
  }) => _channel.invokeMethod('applyAllCameraSettings', {
    'whiteBalance': whiteBalance,
    'exposure': exposure,
    'focus': focus,
    'iso': iso,
    'flash': flash,
  });

  /// Get available camera capabilities and ranges.
  Future<Map<String, dynamic>> camera2GetCapabilities() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('camera2GetCapabilities');
    return result?.cast<String, dynamic>() ?? {};
  }

  Future<void> camera2SetFocusPoint(double x, double y) =>
      _channel.invokeMethod('camera2SetFocusPoint', {'x': x, 'y': y});
}

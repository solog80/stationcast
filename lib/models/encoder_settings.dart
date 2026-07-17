import 'package:station_broadcast/station_broadcast.dart';

enum ResolutionPreset {
  fullHd(1920, 1080, '1080p'),
  hd(1280, 720, '720p'),
  qHd(960, 540, '540p');

  const ResolutionPreset(this.width, this.height, this.label);

  final int width;
  final int height;
  final String label;
}

/// Encoder settings persisted in app settings; mapped to the plugin's
/// [EncoderConfig] when initializing the engine.
class EncoderSettings {
  const EncoderSettings({
    this.resolution = ResolutionPreset.hd,
    this.fps = 30,
    this.videoBitrateBps = 3000000,
    this.audioBitrateBps = 128000,
    this.codec = BroadcastVideoCodec.h264,
    this.mirrorFrontCamera = false,
  });

  final ResolutionPreset resolution;
  final int fps;
  final int videoBitrateBps;
  final int audioBitrateBps;
  final BroadcastVideoCodec codec;
  final bool mirrorFrontCamera;

  EncoderConfig toEncoderConfig() => EncoderConfig(
    width: resolution.width,
    height: resolution.height,
    fps: fps,
    videoBitrateBps: videoBitrateBps,
    audioBitrateBps: audioBitrateBps,
    codec: codec,
  );

  EncoderSettings copyWith({
    ResolutionPreset? resolution,
    int? fps,
    int? videoBitrateBps,
    int? audioBitrateBps,
    BroadcastVideoCodec? codec,
    bool? mirrorFrontCamera,
  }) => EncoderSettings(
    resolution: resolution ?? this.resolution,
    fps: fps ?? this.fps,
    videoBitrateBps: videoBitrateBps ?? this.videoBitrateBps,
    audioBitrateBps: audioBitrateBps ?? this.audioBitrateBps,
    codec: codec ?? this.codec,
    mirrorFrontCamera: mirrorFrontCamera ?? this.mirrorFrontCamera,
  );

  Map<String, Object?> toJson() => {
    'resolution': resolution.name,
    'fps': fps,
    'videoBitrateBps': videoBitrateBps,
    'audioBitrateBps': audioBitrateBps,
    'codec': codec.name,
    'mirrorFrontCamera': mirrorFrontCamera,
  };

  static EncoderSettings fromJson(Map<String, Object?> json) => EncoderSettings(
    resolution: ResolutionPreset.values.firstWhere(
      (r) => r.name == json['resolution'],
      orElse: () => ResolutionPreset.hd,
    ),
    fps: (json['fps'] as num?)?.toInt() ?? 30,
    videoBitrateBps: (json['videoBitrateBps'] as num?)?.toInt() ?? 3000000,
    audioBitrateBps: (json['audioBitrateBps'] as num?)?.toInt() ?? 128000,
    codec: BroadcastVideoCodec.values.firstWhere(
      (c) => c.name == json['codec'],
      orElse: () => BroadcastVideoCodec.h264,
    ),
    mirrorFrontCamera: (json['mirrorFrontCamera'] as bool?) ?? false,
  );
}

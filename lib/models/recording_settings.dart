import 'package:station_broadcast/station_broadcast.dart';

enum RecordingResolution { p720, p1080, p1440 }

enum RecordingFps { fps24, fps25, fps30 }

extension RecordingResolutionExt on RecordingResolution {
  String get label {
    switch (this) {
      case RecordingResolution.p720:
        return '720p';
      case RecordingResolution.p1080:
        return '1080p';
      case RecordingResolution.p1440:
        return '1440p';
    }
  }

  int get height {
    switch (this) {
      case RecordingResolution.p720:
        return 720;
      case RecordingResolution.p1080:
        return 1080;
      case RecordingResolution.p1440:
        return 1440;
    }
  }
}

extension RecordingFpsExt on RecordingFps {
  String get label {
    switch (this) {
      case RecordingFps.fps24:
        return '24 fps';
      case RecordingFps.fps25:
        return '25 fps';
      case RecordingFps.fps30:
        return '30 fps';
    }
  }

  int get value {
    switch (this) {
      case RecordingFps.fps24:
        return 24;
      case RecordingFps.fps25:
        return 25;
      case RecordingFps.fps30:
        return 30;
    }
  }
}

class RecordingSettings {
  const RecordingSettings({
    this.resolution = RecordingResolution.p1080,
    this.bitrateBps = 6_000_000, // 6 Mbps
    this.fps = RecordingFps.fps25,
    this.codec = BroadcastVideoCodec.h264,
    this.enabled = true,
  });

  final RecordingResolution resolution;
  final int bitrateBps; // bits per second
  final RecordingFps fps;
  final BroadcastVideoCodec codec;
  final bool enabled;

  RecordingSettings copyWith({
    RecordingResolution? resolution,
    int? bitrateBps,
    RecordingFps? fps,
    BroadcastVideoCodec? codec,
    bool? enabled,
  }) =>
      RecordingSettings(
        resolution: resolution ?? this.resolution,
        bitrateBps: bitrateBps ?? this.bitrateBps,
        fps: fps ?? this.fps,
        codec: codec ?? this.codec,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => {
        'resolution': resolution.name,
        'bitrateBps': bitrateBps,
        'fps': fps.name,
        'codec': codec.name,
        'enabled': enabled,
      };

  static RecordingSettings fromJson(Map<String, Object?> json) =>
      RecordingSettings(
        resolution: RecordingResolution.values.firstWhere(
          (r) => r.name == json['resolution'],
          orElse: () => RecordingResolution.p1080,
        ),
        bitrateBps: (json['bitrateBps'] as num?)?.toInt() ?? 6_000_000,
        fps: RecordingFps.values.firstWhere(
          (f) => f.name == json['fps'],
          orElse: () => RecordingFps.fps25,
        ),
        codec: BroadcastVideoCodec.values.firstWhere(
          (c) => c.name == json['codec'],
          orElse: () => BroadcastVideoCodec.h264,
        ),
        enabled: (json['enabled'] as bool?) ?? true,
      );
}

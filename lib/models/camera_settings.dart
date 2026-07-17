/// Full manual control over Camera2 capabilities
class CameraSettings {
  const CameraSettings({
    this.zoom = 1.0,
    this.focusMode = FocusMode.auto,
    this.exposureCompensation = 0,
    this.whiteBalance = WhiteBalanceMode.auto,
    this.isoSensitivity = 100,
    this.videoStabilization = true,
    this.flashMode = FlashMode.off,
    this.sceneMode,
    this.effectMode,
    this.faceDetection = false,
    this.mirrorFrontCamera = false,
  });

  final double zoom;
  final FocusMode focusMode;
  final int exposureCompensation; // -4 to +4 typically
  final WhiteBalanceMode whiteBalance;
  final int isoSensitivity;
  final bool videoStabilization;
  final FlashMode flashMode;
  final SceneMode? sceneMode;
  final EffectMode? effectMode;
  final bool faceDetection;
  final bool mirrorFrontCamera;

  CameraSettings copyWith({
    double? zoom,
    FocusMode? focusMode,
    int? exposureCompensation,
    WhiteBalanceMode? whiteBalance,
    int? isoSensitivity,
    bool? videoStabilization,
    FlashMode? flashMode,
    SceneMode? sceneMode,
    EffectMode? effectMode,
    bool? faceDetection,
    bool? mirrorFrontCamera,
  }) =>
      CameraSettings(
        zoom: zoom ?? this.zoom,
        focusMode: focusMode ?? this.focusMode,
        exposureCompensation: exposureCompensation ?? this.exposureCompensation,
        whiteBalance: whiteBalance ?? this.whiteBalance,
        isoSensitivity: isoSensitivity ?? this.isoSensitivity,
        videoStabilization: videoStabilization ?? this.videoStabilization,
        flashMode: flashMode ?? this.flashMode,
        sceneMode: sceneMode ?? this.sceneMode,
        effectMode: effectMode ?? this.effectMode,
        faceDetection: faceDetection ?? this.faceDetection,
        mirrorFrontCamera: mirrorFrontCamera ?? this.mirrorFrontCamera,
      );

  Map<String, Object?> toJson() => {
        'zoom': zoom,
        'focusMode': focusMode.name,
        'exposureCompensation': exposureCompensation,
        'whiteBalance': whiteBalance.name,
        'isoSensitivity': isoSensitivity,
        'videoStabilization': videoStabilization,
        'flashMode': flashMode.name,
        'sceneMode': sceneMode?.name,
        'effectMode': effectMode?.name,
        'faceDetection': faceDetection,
        'mirrorFrontCamera': mirrorFrontCamera,
      };

  static CameraSettings fromJson(Map<String, Object?> json) => CameraSettings(
        zoom: (json['zoom'] as num?)?.toDouble() ?? 1.0,
        focusMode: FocusMode.values.firstWhere(
          (m) => m.name == json['focusMode'],
          orElse: () => FocusMode.auto,
        ),
        exposureCompensation: (json['exposureCompensation'] as num?)?.toInt() ?? 0,
        whiteBalance: WhiteBalanceMode.values.firstWhere(
          (m) => m.name == json['whiteBalance'],
          orElse: () => WhiteBalanceMode.auto,
        ),
        isoSensitivity: (json['isoSensitivity'] as num?)?.toInt() ?? 100,
        videoStabilization: (json['videoStabilization'] as bool?) ?? true,
        flashMode: FlashMode.values.firstWhere(
          (m) => m.name == json['flashMode'],
          orElse: () => FlashMode.off,
        ),
        sceneMode: json['sceneMode'] != null
            ? SceneMode.values.firstWhere(
                (m) => m.name == json['sceneMode'],
                orElse: () => SceneMode.none,
              )
            : null,
        effectMode: json['effectMode'] != null
            ? EffectMode.values.firstWhere(
                (m) => m.name == json['effectMode'],
                orElse: () => EffectMode.none,
              )
            : null,
        faceDetection: (json['faceDetection'] as bool?) ?? false,
        mirrorFrontCamera: (json['mirrorFrontCamera'] as bool?) ?? false,
      );
}

enum FocusMode {
  auto,
  continuous,
  manual,
  macro,
  infinity,
}

enum WhiteBalanceMode {
  auto,
  incandescent,
  fluorescent,
  warmFluorescent,
  daylight,
  cloudyDaylight,
  twilight,
  shade,
}

enum FlashMode {
  off,
  on,
  auto,
  torch,
}

enum SceneMode {
  none,
  action,
  portrait,
  landscape,
  night,
  nightPortrait,
  theatre,
  beach,
  snow,
  sunset,
  steadyPhoto,
  fireworks,
  sports,
  party,
  candlelight,
  barcode,
  hdr,
}

enum EffectMode {
  none,
  mono,
  negative,
  posterize,
  sepia,
  solarize,
  whiteboard,
  blackboard,
  aqua,
}
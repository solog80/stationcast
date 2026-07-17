import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/camera_settings.dart';
import '../models/destination_preset.dart';
import '../models/encoder_settings.dart';
import '../utils/log.dart';
import 'providers.dart';

class BroadcastUiState {
  const BroadcastUiState({
    this.connection = BroadcastConnectionState.idle,
    this.initialized = false,
    this.muted = false,
    this.torchOn = false,
    this.zoom = 1.0,
    this.maxZoom = 1.0,
    this.cameraAspectRatio = 16 / 9,
    this.liveSince,
    this.errorMessage,
    this.activePreset,
    this.reconnectAttempt = 0,
    this.showFrameGuides = true,
    this.showHistogram = false,
  });

  final BroadcastConnectionState connection;
  final bool initialized;
  final bool muted;
  final bool torchOn;
  final double zoom;
  final double maxZoom;
  final double cameraAspectRatio;
  final DateTime? liveSince;
  final String? errorMessage;
  final DestinationPreset? activePreset;
  final int reconnectAttempt;
  final bool showFrameGuides;
  final bool showHistogram;

  bool get isLive => connection == BroadcastConnectionState.live;
  bool get isBusy =>
      connection == BroadcastConnectionState.connecting ||
      connection == BroadcastConnectionState.reconnecting;

  BroadcastUiState copyWith({
    BroadcastConnectionState? connection,
    bool? initialized,
    bool? muted,
    bool? torchOn,
    double? zoom,
    double? maxZoom,
    double? cameraAspectRatio,
    DateTime? liveSince,
    bool clearLiveSince = false,
    String? errorMessage,
    bool clearError = false,
    DestinationPreset? activePreset,
    int? reconnectAttempt,
    bool? showFrameGuides,
    bool? showHistogram,
  }) => BroadcastUiState(
    connection: connection ?? this.connection,
    initialized: initialized ?? this.initialized,
    muted: muted ?? this.muted,
    torchOn: torchOn ?? this.torchOn,
    zoom: zoom ?? this.zoom,
    maxZoom: maxZoom ?? this.maxZoom,
    cameraAspectRatio: cameraAspectRatio ?? this.cameraAspectRatio,
    liveSince: clearLiveSince ? null : (liveSince ?? this.liveSince),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    activePreset: activePreset ?? this.activePreset,
    reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
    showFrameGuides: showFrameGuides ?? this.showFrameGuides,
    showHistogram: showHistogram ?? this.showHistogram,
  );
}

/// Orchestrates the native engine: lifecycle, camera controls and
/// reconnect-with-backoff when the link drops mid-broadcast.
class BroadcastController extends Notifier<BroadcastUiState> {
  static const _maxReconnectAttempts = 3;

  StreamSubscription<BroadcastEvent>? _eventSub;
  bool _wantLive = false;

  StationBroadcast get _plugin => ref.read(broadcastPluginProvider);

  @override
  BroadcastUiState build() {
    _eventSub?.cancel();
    _eventSub = _plugin.events.listen(_onEngineEvent);

    ref.onDispose(() {
      _eventSub?.cancel();
      _plugin.dispose();
    });
    return const BroadcastUiState();
  }

  Future<void> initialize(EncoderSettings encoder) async {
    await _plugin.initialize(encoder.toEncoderConfig());
    await _plugin.setMirrorFrontCamera(encoder.mirrorFrontCamera);

    // Initialize Camera2Manager for preview-time camera settings
    try {
      await _plugin.camera2InitializeManager();
      final camera = await ref.read(cameraSettingsProvider.future);
      await applyCameraSettings(camera);
    } catch (_) {
      // Camera2 not available on this device/platform
    }

    final maxZoom = await _plugin.getMaxZoom();
    double aspectRatio = 16 / 9;
    try {
      final resolution =
          await _plugin.getCameraResolution() as Map<dynamic, dynamic>?;
      log('[BroadcastController] getCameraResolution result: $resolution');
      if (resolution != null && resolution['aspectRatio'] is num) {
        aspectRatio = (resolution['aspectRatio'] as num).toDouble();
        log('[BroadcastController] Using aspect ratio: $aspectRatio');
      } else {
        log(
          '[BroadcastController] No valid aspectRatio in resolution, using default',
        );
      }
    } catch (e) {
      log('[BroadcastController] getCameraResolution failed: $e');
    }
    await WakelockPlus.enable();
    state = state.copyWith(
      initialized: true,
      maxZoom: maxZoom,
      cameraAspectRatio: aspectRatio,
    );
  }

  Future<void> goLive(DestinationPreset preset) async {
    if (state.isLive || state.isBusy) return;
    _wantLive = true;
    state = state.copyWith(
      activePreset: preset,
      clearError: true,
      reconnectAttempt: 0,
    );
    try {
      await _plugin.startStream(preset.toDestinationConfig());
    } catch (e) {
      _wantLive = false;
      state = state.copyWith(
        connection: BroadcastConnectionState.failed,
        errorMessage: '$e',
      );
    }
  }

  Future<void> stop() async {
    _wantLive = false;
    await _plugin.stopStream();
    state = state.copyWith(
      connection: BroadcastConnectionState.stopped,
      clearLiveSince: true,
      reconnectAttempt: 0,
    );
  }

  void toggleFrameGuides() =>
      state = state.copyWith(showFrameGuides: !state.showFrameGuides);
  void toggleHistogram() =>
      state = state.copyWith(showHistogram: !state.showHistogram);

  Future<void> switchCamera() async {
    await _plugin.switchCamera();
    // Torch resets when the camera flips; zoom range differs per camera.
    final maxZoom = await _plugin.getMaxZoom();
    state = state.copyWith(torchOn: false, zoom: 1.0, maxZoom: maxZoom);
    // Apply mirror setting for front camera
    final encoder = await ref.read(encoderSettingsProvider.future);
    await _plugin.setMirrorFrontCamera(encoder.mirrorFrontCamera);
  }

  Future<void> toggleTorch() async {
    final next = !state.torchOn;
    await _plugin.setTorch(next);
    state = state.copyWith(torchOn: next);
  }

  Future<void> setZoom(double ratio) async {
    final clamped = ratio.clamp(0.5, state.maxZoom);
    await _plugin.setZoom(clamped);
    state = state.copyWith(zoom: clamped);
  }

  Future<void> toggleMute() async {
    final next = !state.muted;
    await _plugin.setMuted(next);
    state = state.copyWith(muted: next);
  }

  Future<void> selectAudioDevice(String id) => _plugin.selectAudioDevice(id);

  Future<List<BroadcastAudioDevice>> getAudioDevices() =>
      _plugin.getAudioDevices();

  // Camera2 control methods
  Future<void> applyCameraSettings(CameraSettings camera) async {
    try {
      await _plugin.camera2SetZoom(camera.zoom);
      // Try batch (iOS), fall back to individual (Android)
      try {
        await _plugin.applyAllCameraSettings(
          whiteBalance: camera.whiteBalance.name,
          exposure: camera.exposureCompensation,
          focus: camera.focusMode.name,
          iso: camera.isoSensitivity,
          flash: camera.flashMode.name,
        );
      } catch (_) {
        await _plugin.camera2SetFocusMode(camera.focusMode.name);
        await _plugin.camera2SetExposureCompensation(
          camera.exposureCompensation,
        );
        await _plugin.camera2SetWhiteBalance(camera.whiteBalance.name);
        await _plugin.camera2SetIsoSensitivity(camera.isoSensitivity);
        await _plugin.camera2SetFlashMode(camera.flashMode.name);
      }
      await _plugin.camera2SetVideoStabilization(camera.videoStabilization);
    } catch (e) {
      // Camera2 settings are best-effort; don't fail if not available
    }
  }

  Future<void> setCameraZoom(double ratio) async {
    await _plugin.camera2SetZoom(ratio);
  }

  Future<void> setCameraFocusMode(FocusMode mode) async {
    await _plugin.camera2SetFocusMode(mode.name);
  }

  Future<void> setCameraExposure(int ev) async {
    await _plugin.camera2SetExposureCompensation(ev);
  }

  Future<void> setCameraWhiteBalance(WhiteBalanceMode mode) async {
    await _plugin.camera2SetWhiteBalance(mode.name);
  }

  Future<void> setCameraIso(int iso) async {
    await _plugin.camera2SetIsoSensitivity(iso);
  }

  Future<void> setCameraVideoStabilization(bool enabled) async {
    await _plugin.camera2SetVideoStabilization(enabled);
  }

  Future<void> setCameraFlashMode(FlashMode mode) async {
    await _plugin.camera2SetFlashMode(mode.name);
  }

  Future<Map<String, dynamic>> getCameraCapabilities() =>
      _plugin.camera2GetCapabilities();

  Future<void> setFocusPoint(double x, double y) =>
      _plugin.camera2SetFocusPoint(x, y);

  void _onEngineEvent(BroadcastEvent event) {
    switch (event.state) {
      case BroadcastConnectionState.live:
        state = state.copyWith(
          connection: BroadcastConnectionState.live,
          liveSince: state.liveSince ?? DateTime.now(),
          clearError: true,
          reconnectAttempt: 0,
        );
      case BroadcastConnectionState.connecting:
        state = state.copyWith(connection: BroadcastConnectionState.connecting);
      case BroadcastConnectionState.failed:
        if (_wantLive) {
          _attemptReconnect(event.message);
        } else {
          state = state.copyWith(
            connection: BroadcastConnectionState.failed,
            errorMessage: event.message,
            clearLiveSince: true,
          );
        }
      case BroadcastConnectionState.stopped:
        if (!_wantLive) {
          state = state.copyWith(
            connection: BroadcastConnectionState.stopped,
            clearLiveSince: true,
          );
        }
      case BroadcastConnectionState.reconnecting:
      case BroadcastConnectionState.idle:
        state = state.copyWith(connection: event.state);
    }
  }

  Future<void> _attemptReconnect(String? reason) async {
    final preset = state.activePreset;
    if (preset == null) return;
    final attempt = state.reconnectAttempt + 1;
    if (attempt > _maxReconnectAttempts) {
      _wantLive = false;
      state = state.copyWith(
        connection: BroadcastConnectionState.failed,
        errorMessage: reason ?? 'Connection lost',
        clearLiveSince: true,
      );
      return;
    }
    state = state.copyWith(
      connection: BroadcastConnectionState.reconnecting,
      reconnectAttempt: attempt,
      errorMessage: reason,
    );
    await Future<void>.delayed(Duration(seconds: 2 * attempt));
    if (!_wantLive) return;
    try {
      await _plugin.startStream(preset.toDestinationConfig());
    } catch (e) {
      // The failed event from the engine re-enters this path for the
      // next attempt; nothing to do here.
    }
  }
}

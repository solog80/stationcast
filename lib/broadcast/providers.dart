import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../models/camera_settings.dart';
import '../models/destination_preset.dart';
import '../models/encoder_settings.dart';
import '../models/recording_settings.dart';
import '../models/return_feed_config.dart';
import '../services/auth_service.dart';
import '../services/broadcast_reporter.dart';
import '../services/settings_repository.dart';
import '../services/broadcast_config_bff.dart';
import '../services/mesh_broadcast_config.dart';
import '../services/settings_sync.dart';
import '../utils/log.dart';
import 'broadcast_controller.dart';

final broadcastPluginProvider = Provider<StationBroadcast>(
  (ref) => StationBroadcast(),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(),
);

final broadcastControllerProvider =
    NotifierProvider<BroadcastController, BroadcastUiState>(
      BroadcastController.new,
    );

/// Link statistics straight from the native engine (~1 Hz while live).
final statsProvider = StreamProvider<StreamStats>((ref) {
  final raw = ref.watch(broadcastPluginProvider).stats;
  var lastFull = StreamStats();
  return raw.map((s) {
    // Merge: if map only has audioLevelDb, merge into last full stats
    if (s.bitrateBps == 0 && s.rttMs == 0 && s.packetsSent == 0) {
      return lastFull.copyWithAudioLevel(s.audioLevelDb);
    }
    lastFull = s;
    return s;
  });
});

/// Saved destination presets, editable from settings.
class PresetsNotifier extends AsyncNotifier<List<DestinationPreset>> {
  @override
  Future<List<DestinationPreset>> build() async {
    final repo = ref.read(settingsRepositoryProvider);
    final local = await repo.loadPresets();
    var result = local;
    final auth = ref.read(authServiceProvider);

    if (auth.isSignedIn) {
      // Initial pull from the dashboard-provisioned tv.destinations (BFF first,
      // then the mesh directly if the BFF is unreachable).
      Map<String, dynamic>? tv;
      try {
        tv = await fetchTvConfig();
      } catch (_) {}
      tv ??= _tvFromMeshConfig(
        await ref.read(meshBroadcastConfigProvider).fetchConfig(),
      );
      final remotes = _destinationsFromTv(tv);
      if (remotes != null) {
        result = remotes;
        await repo.savePresets(remotes);
        log('[Presets] loaded ${remotes.length} remote destination(s)');
      }

      // Live updates when the dashboard adds/edits destinations.
      var disposed = false;
      final sub = ref.read(meshBroadcastConfigProvider).configChanges().listen((
        row,
      ) async {
        if (disposed) return;
        final tvRow = row['tv'];
        final list = _destinationsFromTv(
          tvRow is Map ? tvRow.cast<String, dynamic>() : null,
        );
        if (list == null) return;
        await repo.savePresets(list);
        state = AsyncData(list);
        log('[Presets] live destinations update (${list.length})');
      });
      ref.onDispose(() {
        disposed = true;
        sub.cancel();
      });
    }

    return result;
  }

  Future<void> upsert(DestinationPreset preset) async {
    var current = [...state.value ?? <DestinationPreset>[]];
    if (preset.isDefault) {
      current = current.map((p) => p.copyWith(isDefault: false)).toList();
    }
    final index = current.indexWhere((p) => p.id == preset.id);
    if (index >= 0) {
      current[index] = preset;
    } else {
      current.add(preset);
    }
    state = AsyncData(current);
    await ref.read(settingsRepositoryProvider).savePresets(current);
    if (ref.read(authServiceProvider).isSignedIn) {
      final config =
          ref.read(returnFeedConfigProvider).valueOrNull ??
          const ReturnFeedConfig();
      await saveConfigToCloud(config, destinations: current);
    }
  }

  Future<void> setDefault(String id) async {
    final current = (state.value ?? []).map((p) {
      return p.copyWith(isDefault: p.id == id);
    }).toList();
    state = AsyncData(current);
    await ref.read(settingsRepositoryProvider).savePresets(current);
    if (ref.read(authServiceProvider).isSignedIn) {
      final config =
          ref.read(returnFeedConfigProvider).valueOrNull ??
          const ReturnFeedConfig();
      await saveConfigToCloud(config, destinations: current);
    }
  }

  Future<void> remove(String id) async {
    final current = [...state.value ?? <DestinationPreset>[]]
      ..removeWhere((p) => p.id == id);
    state = AsyncData(current);
    await ref.read(settingsRepositoryProvider).savePresets(current);
    if (ref.read(authServiceProvider).isSignedIn) {
      final config =
          ref.read(returnFeedConfigProvider).valueOrNull ??
          const ReturnFeedConfig();
      await saveConfigToCloud(config, destinations: current);
    }
  }
}

final presetsProvider =
    AsyncNotifierProvider<PresetsNotifier, List<DestinationPreset>>(
      PresetsNotifier.new,
    );

class EncoderSettingsNotifier extends AsyncNotifier<EncoderSettings> {
  @override
  Future<EncoderSettings> build() async {
    final repo = ref.read(settingsRepositoryProvider);
    var local = await repo.loadEncoderSettings();
    final auth = ref.read(authServiceProvider);

    if (auth.isSignedIn) {
      Map<String, dynamic>? tv;
      try {
        tv = await fetchTvConfig();
      } catch (_) {}
      try {
        tv ??= _tvFromMeshConfig(
          await ref.read(meshBroadcastConfigProvider).fetchConfig(),
        );
      } catch (_) {}
      if (tv != null) {
        local = encoderSettingsFromTv(local, tv);
        await repo.saveEncoderSettings(local);
      }

      var disposed = false;
      final sub = ref.read(meshBroadcastConfigProvider).configChanges().listen((
        row,
      ) async {
        if (disposed) return;
        final t = row['tv'];
        if (t is! Map) return;
        final cur = state.valueOrNull ?? local;
        final next = encoderSettingsFromTv(cur, t.cast<String, dynamic>());
        if (_encoderEquals(cur, next)) return;
        await repo.saveEncoderSettings(next);
        state = AsyncData(next);
        log('[Encoder] live remote update');
      });
      ref.onDispose(() {
        disposed = true;
        sub.cancel();
      });
    }
    return local;
  }

  Future<void> save(EncoderSettings settings) async {
    state = AsyncData(settings);
    await ref.read(settingsRepositoryProvider).saveEncoderSettings(settings);

    // Sync to the mesh in the background (tv.encoder*).
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await BroadcastConfigBff().saveTv({
          'encoderCodec': settings.codec == BroadcastVideoCodec.hevc
              ? 'hevc'
              : 'avc',
          'encoderBitrate': settings.videoBitrateBps,
          'encoderFps': settings.fps,
          'audioBitrateBps': settings.audioBitrateBps,
          'encoderResolution': settings.resolution.label,
          'mirrorFrontCamera': settings.mirrorFrontCamera,
          'oledPowerSaverEnabled': settings.oledPowerSaverEnabled,
          'oledPowerSaverTimeoutSeconds': settings.oledPowerSaverTimeoutSeconds,
        });
      }
    } catch (_) {}
  }
}

final encoderSettingsProvider =
    AsyncNotifierProvider<EncoderSettingsNotifier, EncoderSettings>(
      EncoderSettingsNotifier.new,
    );

class CameraSettingsNotifier extends AsyncNotifier<CameraSettings> {
  @override
  Future<CameraSettings> build() =>
      ref.read(settingsRepositoryProvider).loadCameraSettings();

  Future<void> save(CameraSettings settings) async {
    final oldSettings = state.valueOrNull;
    state = AsyncData(settings);
    await ref.read(settingsRepositoryProvider).saveCameraSettings(settings);

    // Only apply changed settings to avoid resetting pinch zoom or other native state
    try {
      final broadcastController = ref.read(
        broadcastControllerProvider.notifier,
      );

      // Check if only videoStabilization changed
      if (oldSettings != null &&
          oldSettings.zoom == settings.zoom &&
          oldSettings.whiteBalance == settings.whiteBalance &&
          oldSettings.exposureCompensation == settings.exposureCompensation &&
          oldSettings.isoSensitivity == settings.isoSensitivity &&
          oldSettings.focusMode == settings.focusMode &&
          oldSettings.flashMode == settings.flashMode &&
          oldSettings.videoStabilization != settings.videoStabilization) {
        // Only EIS changed - apply just that
        log(
          '[CameraSettings] Only EIS changed: ${settings.videoStabilization}',
        );
        await broadcastController.setVideoStabilizationOnly(
          settings.videoStabilization,
        );
      } else {
        // Multiple settings changed or first time - apply all
        log(
          '[CameraSettings] Applying all settings: Zoom=${settings.zoom} EIS=${settings.videoStabilization}',
        );
        await broadcastController.applyCameraSettings(settings);
      }
    } catch (e) {
      log('[CameraSettings] apply error: $e');
    }
  }
}

final cameraSettingsProvider =
    AsyncNotifierProvider<CameraSettingsNotifier, CameraSettings>(
      CameraSettingsNotifier.new,
    );

final cameraCapabilitiesFutureProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final plugin = ref.read(broadcastPluginProvider);
  try {
    final caps = await plugin.camera2GetCapabilities();
    return caps.cast<String, dynamic>();
  } catch (_) {
    return {
      'exposureCompensationRange': {'min': -4, 'max': 4},
    };
  }
});

/// Side effect: Apply camera settings in real-time when they change (preview mode only)
/// Skip during live streaming to preserve pinch-zoom on native preview
final cameraSettingsEffectProvider = FutureProvider<void>((ref) async {
  final broadcastState = ref.watch(broadcastControllerProvider);
  final broadcastController = ref.watch(broadcastControllerProvider.notifier);
  final camera = await ref.watch(cameraSettingsProvider.future);

  // Only apply settings during preview; skip during live to preserve pinch zoom
  if (broadcastState.isLive) return;

  try {
    await broadcastController.applyCameraSettings(camera);
  } catch (_) {
    // Settings application is best-effort
  }
});

class ReturnFeedConfigNotifier extends AsyncNotifier<ReturnFeedConfig> {
  @override
  Future<ReturnFeedConfig> build() async {
    final local = await ref
        .read(settingsRepositoryProvider)
        .loadReturnFeedConfig();
    final auth = ref.read(authServiceProvider);

    // Live TV settings from the dashboard (mesh Realtime).
    if (auth.isSignedIn) {
      var disposed = false;
      final sub = ref.read(meshBroadcastConfigProvider).configChanges().listen((
        row,
      ) async {
        if (disposed) return;
        final tv = row['tv'];
        if (tv is! Map) return;
        final data = tv.cast<String, dynamic>();
        final current = state.valueOrNull ?? local;
        var merged = returnFeedConfigFromTv(data);
        if (merged.broadcasterId.isEmpty) {
          merged = merged.copyWith(broadcasterId: current.broadcasterId);
        }
        if (merged.broadcasterName.isEmpty) {
          merged = merged.copyWith(broadcasterName: current.broadcasterName);
        }
        await ref.read(settingsRepositoryProvider).saveReturnFeedConfig(merged);
        state = AsyncData(merged);
        await _applyEncoderFromTv(data);
        log('[SettingsSync] live remote tv update');
      });
      ref.onDispose(() {
        disposed = true;
        sub.cancel();
      });
    }

    if (auth.isSignedIn) {
      // Load the TV config from the dashboard (BFF first, mesh direct second).
      Map<String, dynamic>? tv;
      try {
        tv = await fetchTvConfig();
      } catch (_) {}
      try {
        tv ??= _tvFromMeshConfig(
          await ref.read(meshBroadcastConfigProvider).fetchConfig(),
        );
      } catch (_) {}

      try {
        final remote = tv != null ? returnFeedConfigFromTv(tv) : null;
        if (remote != null) {
          final merged = remote.copyWith(
            // Remote (dashboard) values win when present so the name/ID match
            // what the admin sees; local values are only a fallback.
            broadcasterId: remote.broadcasterId.isNotEmpty
                ? remote.broadcasterId
                : local.broadcasterId.isNotEmpty
                ? local.broadcasterId
                : auth.userId,
            broadcasterName: remote.broadcasterName.isNotEmpty
                ? remote.broadcasterName
                : local.broadcasterName.isNotEmpty
                ? local.broadcasterName
                : auth.displayName.isNotEmpty
                ? auth.displayName
                : auth.email,
          );
          await ref
              .read(settingsRepositoryProvider)
              .saveReturnFeedConfig(merged);
          log('[SettingsSync] loaded remote config');
          ref
              .read(broadcastReporterProvider)
              .register(merged.broadcasterId, merged.broadcasterName);

          // Apply remote encoder settings from the same tv object.
          try {
            if (tv != null) await _applyEncoderFromTv(tv);
          } catch (_) {}
          return merged;
        }
      } catch (e) {
        log('[SettingsSync] start sync error: $e');
      }

      // First sign-in: set defaults from auth profile
      if (local.broadcasterId.isEmpty) {
        final updated = local.copyWith(
          broadcasterId: auth.userId,
          broadcasterName: auth.displayName.isNotEmpty
              ? auth.displayName
              : auth.email,
        );
        await ref
            .read(settingsRepositoryProvider)
            .saveReturnFeedConfig(updated);
        // Register in Firestore so dashboard finds this broadcaster
        ref
            .read(broadcastReporterProvider)
            .register(auth.userId, updated.broadcasterName);
        return updated;
      }
    }

    // Signed in with broadcasterId already set — register to ensure Firestore doc exists
    if (auth.isSignedIn && local.broadcasterId.isNotEmpty) {
      ref
          .read(broadcastReporterProvider)
          .register(local.broadcasterId, local.broadcasterName);
    }

    return local;
  }

  Future<void> save(ReturnFeedConfig config) async {
    state = AsyncData(config);
    await ref.read(settingsRepositoryProvider).saveReturnFeedConfig(config);

    // Sync to the mesh in the background
    if (ref.read(authServiceProvider).isSignedIn) {
      try {
        final presets = ref.read(presetsProvider).valueOrNull;
        await saveConfigToCloud(config, destinations: presets);
      } catch (e) {
        log('[SettingsSync] save sync error: $e');
      }
    }
  }

  /// Applies encoder fields from the mesh `tv` object without echoing back
  /// (avoids a Realtime write->update loop).
  Future<void> _applyEncoderFromTv(Map<String, dynamic> data) async {
    final rc = data['encoderCodec'] as String?;
    final rb = data['encoderBitrate'] as int?;
    final rf = data['encoderFps'] as int?;
    final ra = data['audioBitrateBps'] as int?;
    if (rc == null && rb == null && rf == null && ra == null) return;

    final cur = await ref.read(encoderSettingsProvider.future);
    final upd = cur.copyWith(
      codec: rc == 'hevc' ? BroadcastVideoCodec.hevc : BroadcastVideoCodec.h264,
      videoBitrateBps: rb ?? cur.videoBitrateBps,
      fps: rf ?? cur.fps,
      audioBitrateBps: ra ?? cur.audioBitrateBps,
    );
    if (upd.codec == cur.codec &&
        upd.videoBitrateBps == cur.videoBitrateBps &&
        upd.fps == cur.fps &&
        upd.audioBitrateBps == cur.audioBitrateBps) {
      return;
    }
    await ref.read(encoderSettingsProvider.notifier).save(upd);
  }
}

final returnFeedConfigProvider =
    AsyncNotifierProvider<ReturnFeedConfigNotifier, ReturnFeedConfig>(
      ReturnFeedConfigNotifier.new,
    );

class RecordingSettingsNotifier extends AsyncNotifier<RecordingSettings> {
  @override
  Future<RecordingSettings> build() async {
    final repo = ref.read(settingsRepositoryProvider);
    var local = await repo.loadRecordingSettings();
    final auth = ref.read(authServiceProvider);

    if (auth.isSignedIn) {
      Map<String, dynamic>? tv;
      try {
        tv = await fetchTvConfig();
      } catch (_) {}
      try {
        tv ??= _tvFromMeshConfig(
          await ref.read(meshBroadcastConfigProvider).fetchConfig(),
        );
      } catch (_) {}
      if (tv != null) {
        local = recordingSettingsFromTv(local, tv);
        await repo.saveRecordingSettings(local);
      }

      var disposed = false;
      final sub = ref.read(meshBroadcastConfigProvider).configChanges().listen((
        row,
      ) async {
        if (disposed) return;
        final t = row['tv'];
        if (t is! Map) return;
        final cur = state.valueOrNull ?? local;
        final next = recordingSettingsFromTv(cur, t.cast<String, dynamic>());
        if (_recordingEquals(cur, next)) return;
        await repo.saveRecordingSettings(next);
        state = AsyncData(next);
        log('[Recording] live remote update');
      });
      ref.onDispose(() {
        disposed = true;
        sub.cancel();
      });
    }
    return local;
  }

  Future<void> save(RecordingSettings settings) async {
    state = AsyncData(settings);
    await ref.read(settingsRepositoryProvider).saveRecordingSettings(settings);
    try {
      if (FirebaseAuth.instance.currentUser != null) {
        await BroadcastConfigBff().saveTv({
          'recordingEnabled': settings.enabled,
          'recordingResolution': settings.resolution.label,
          'recordingBitrate': settings.bitrateBps,
          'recordingFps': settings.fps.value,
          'recordingCodec': settings.codec == BroadcastVideoCodec.hevc
              ? 'hevc'
              : 'avc',
        });
      }
    } catch (_) {}
  }
}

final recordingSettingsProvider =
    AsyncNotifierProvider<RecordingSettingsNotifier, RecordingSettings>(
      RecordingSettingsNotifier.new,
    );

Map<String, dynamic>? _tvFromMeshConfig(Map<String, dynamic>? config) {
  if (config == null) return null;
  final tv = config['tv'];
  if (tv is Map<String, dynamic>) return tv;
  if (tv is Map) return tv.cast<String, dynamic>();
  return null;
}

/// Returns null when the `destinations` key is absent (unknown) so callers do
/// not overwrite local state; returns [] when the dashboard cleared the list.
List<DestinationPreset>? _destinationsFromTv(Map<String, dynamic>? tv) {
  final list = tv?['destinations'];
  if (list is! List) return null;
  return list
      .map(
        (d) => DestinationPreset.fromJson((d as Map).cast<String, Object?>()),
      )
      .toList();
}

EncoderSettings encoderSettingsFromTv(
  EncoderSettings cur,
  Map<String, dynamic> tv,
) {
  final label = tv['encoderResolution'];
  final resolution = label is String
      ? ResolutionPreset.values.firstWhere(
          (r) => r.label == label,
          orElse: () => cur.resolution,
        )
      : cur.resolution;
  final codecRaw = tv['encoderCodec'];
  final codec = codecRaw == 'hevc'
      ? BroadcastVideoCodec.hevc
      : codecRaw == 'avc'
      ? BroadcastVideoCodec.h264
      : cur.codec;
  return cur.copyWith(
    resolution: resolution,
    fps: (tv['encoderFps'] as num?)?.toInt() ?? cur.fps,
    videoBitrateBps:
        (tv['encoderBitrate'] as num?)?.toInt() ?? cur.videoBitrateBps,
    audioBitrateBps:
        (tv['audioBitrateBps'] as num?)?.toInt() ?? cur.audioBitrateBps,
    codec: codec,
    mirrorFrontCamera:
        tv['mirrorFrontCamera'] as bool? ?? cur.mirrorFrontCamera,
    oledPowerSaverEnabled:
        tv['oledPowerSaverEnabled'] as bool? ?? cur.oledPowerSaverEnabled,
    oledPowerSaverTimeoutSeconds:
        (tv['oledPowerSaverTimeoutSeconds'] as num?)?.toInt() ??
        cur.oledPowerSaverTimeoutSeconds,
  );
}

RecordingSettings recordingSettingsFromTv(
  RecordingSettings cur,
  Map<String, dynamic> tv,
) {
  final label = tv['recordingResolution'];
  final resolution = label is String
      ? RecordingResolution.values.firstWhere(
          (r) => r.label == label || r.name == label,
          orElse: () => cur.resolution,
        )
      : cur.resolution;
  final fpsNum = (tv['recordingFps'] as num?)?.toInt();
  final fps = fpsNum == null
      ? cur.fps
      : RecordingFps.values.firstWhere(
          (f) => f.value == fpsNum,
          orElse: () => cur.fps,
        );
  final codecRaw = tv['recordingCodec'];
  final codec = codecRaw == 'hevc'
      ? BroadcastVideoCodec.hevc
      : codecRaw == 'avc'
      ? BroadcastVideoCodec.h264
      : cur.codec;
  return cur.copyWith(
    resolution: resolution,
    bitrateBps: (tv['recordingBitrate'] as num?)?.toInt() ?? cur.bitrateBps,
    fps: fps,
    codec: codec,
    enabled: tv['recordingEnabled'] as bool? ?? cur.enabled,
  );
}

bool _encoderEquals(EncoderSettings a, EncoderSettings b) =>
    a.resolution == b.resolution &&
    a.fps == b.fps &&
    a.videoBitrateBps == b.videoBitrateBps &&
    a.audioBitrateBps == b.audioBitrateBps &&
    a.codec == b.codec &&
    a.mirrorFrontCamera == b.mirrorFrontCamera &&
    a.oledPowerSaverEnabled == b.oledPowerSaverEnabled &&
    a.oledPowerSaverTimeoutSeconds == b.oledPowerSaverTimeoutSeconds;

bool _recordingEquals(RecordingSettings a, RecordingSettings b) =>
    a.resolution == b.resolution &&
    a.bitrateBps == b.bitrateBps &&
    a.fps == b.fps &&
    a.codec == b.codec &&
    a.enabled == b.enabled;

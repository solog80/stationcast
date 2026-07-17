import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../models/camera_settings.dart';
import '../models/destination_preset.dart';
import '../models/encoder_settings.dart';
import '../models/return_feed_config.dart';
import '../services/auth_service.dart';
import '../services/broadcast_reporter.dart';
import '../services/settings_repository.dart';
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
    final local = await ref.read(settingsRepositoryProvider).loadPresets();

    // Merge remote destinations from Firestore (if signed in)
    final auth = ref.read(authServiceProvider);
    if (auth.isSignedIn) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('broadcastConfig')
            .doc('user_${auth.userId}')
            .get();
        if (doc.exists) {
          final remoteDests = (doc.data()!['destinations'] as List<dynamic>?)
              ?.cast<Map<String, dynamic>>();
          if (remoteDests != null && remoteDests.isNotEmpty) {
            final remotes = remoteDests
                .map(
                  (d) => DestinationPreset(
                    id:
                        d['id'] as String? ??
                        DateTime.now().microsecondsSinceEpoch.toString(),
                    name: d['name'] as String? ?? '',
                    protocol: (d['protocol'] as String?) == 'rtmp'
                        ? BroadcastProtocol.rtmp
                        : BroadcastProtocol.srt,
                    host: d['host'] as String? ?? '',
                    port: (d['port'] as num?)?.toInt() ?? 8890,
                    streamId: d['streamId'] as String? ?? '',
                    passphrase: d['passphrase'] as String? ?? '',
                    latencyMs: (d['latencyMs'] as num?)?.toInt() ?? 200,
                    rtmpUrl: d['rtmpUrl'] as String? ?? '',
                    streamKey: d['streamKey'] as String? ?? '',
                  ),
                )
                .toList();
            // Save remote destinations locally so they persist across restarts
            await ref.read(settingsRepositoryProvider).savePresets(remotes);
            return remotes;
          }
        }
      } catch (_) {}
    }

    return local;
  }

  Future<void> upsert(DestinationPreset preset) async {
    final current = [...state.value ?? <DestinationPreset>[]];
    final index = current.indexWhere((p) => p.id == preset.id);
    if (index >= 0) {
      current[index] = preset;
    } else {
      current.add(preset);
    }
    state = AsyncData(current);
    await ref.read(settingsRepositoryProvider).savePresets(current);
  }

  Future<void> remove(String id) async {
    final current = [...state.value ?? <DestinationPreset>[]]
      ..removeWhere((p) => p.id == id);
    state = AsyncData(current);
    await ref.read(settingsRepositoryProvider).savePresets(current);
  }
}

final presetsProvider =
    AsyncNotifierProvider<PresetsNotifier, List<DestinationPreset>>(
      PresetsNotifier.new,
    );

class EncoderSettingsNotifier extends AsyncNotifier<EncoderSettings> {
  @override
  Future<EncoderSettings> build() =>
      ref.read(settingsRepositoryProvider).loadEncoderSettings();

  Future<void> save(EncoderSettings settings) async {
    state = AsyncData(settings);
    await ref.read(settingsRepositoryProvider).saveEncoderSettings(settings);

    // Sync to Firestore in the background
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await FirebaseFirestore.instance
            .collection('broadcastConfig')
            .doc('user_$uid')
            .set({
              'encoderCodec': settings.codec == BroadcastVideoCodec.hevc
                  ? 'hevc'
                  : 'avc',
              'encoderBitrate': settings.videoBitrateBps,
              'encoderFps': settings.fps,
              'audioBitrateBps': settings.audioBitrateBps,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
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
    state = AsyncData(settings);
    await ref.read(settingsRepositoryProvider).saveCameraSettings(settings);

    // Apply settings immediately to the camera
    try {
      final broadcastController = ref.read(
        broadcastControllerProvider.notifier,
      );
      log(
        '[CameraSettings] applying settings: WB=${settings.whiteBalance.name} EV=${settings.exposureCompensation} ISO=${settings.isoSensitivity} Focus=${settings.focusMode.name}',
      );
      await broadcastController.applyCameraSettings(settings);
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

/// Side effect: Apply camera settings in real-time when they change (preview mode)
final cameraSettingsEffectProvider = FutureProvider<void>((ref) async {
  final broadcastController = ref.watch(broadcastControllerProvider.notifier);
  final camera = await ref.watch(cameraSettingsProvider.future);

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

    if (auth.isSignedIn) {
      // Try to load remote settings from Firestore
      try {
        final remote = await loadConfigFromFirestore();
        if (remote != null) {
          final merged = remote.copyWith(
            broadcasterId: local.broadcasterId.isNotEmpty
                ? local.broadcasterId
                : remote.broadcasterId.isNotEmpty
                ? remote.broadcasterId
                : auth.userId,
            broadcasterName: local.broadcasterName.isNotEmpty
                ? local.broadcasterName
                : remote.broadcasterName.isNotEmpty
                ? remote.broadcasterName
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

          // Apply remote encoder settings from raw Firestore data
          try {
            final doc = await FirebaseFirestore.instance
                .collection('broadcastConfig')
                .doc('user_${auth.userId}')
                .get();
            if (doc.exists) {
              final data = doc.data()!;
              final rc = data['encoderCodec'] as String?;
              final rb = data['encoderBitrate'] as int?;
              final rf = data['encoderFps'] as int?;
              final ra = data['audioBitrateBps'] as int?;
              final res = data['encoderResolution'] as String?;
              if (rc != null ||
                  rb != null ||
                  rf != null ||
                  ra != null ||
                  res != null) {
                final cur = await ref.read(encoderSettingsProvider.future);
                final upd = cur.copyWith(
                  codec: rc == 'hevc'
                      ? BroadcastVideoCodec.hevc
                      : BroadcastVideoCodec.h264,
                  videoBitrateBps: rb ?? cur.videoBitrateBps,
                  fps: rf ?? cur.fps,
                  audioBitrateBps: ra ?? cur.audioBitrateBps,
                );
                await ref.read(encoderSettingsProvider.notifier).save(upd);
              }
            }
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

    // Sync to Firestore in the background
    if (ref.read(authServiceProvider).isSignedIn) {
      try {
        final presets = ref.read(presetsProvider).valueOrNull ?? [];
        await saveConfigToFirestore(config, destinations: presets);
      } catch (e) {
        log('[SettingsSync] save sync error: $e');
      }
    }
  }
}

final returnFeedConfigProvider =
    AsyncNotifierProvider<ReturnFeedConfigNotifier, ReturnFeedConfig>(
      ReturnFeedConfigNotifier.new,
    );

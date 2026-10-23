import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../broadcast/providers.dart' show settingsRepositoryProvider;
import '../models/sip_preset.dart';
import '../services/broadcast_config_bff.dart';
import '../services/mesh_broadcast_config.dart';
import '../utils/log.dart';
import 'radio_controller.dart';

final radioSipProvider = Provider<SipClient>((ref) {
  final client = SipClient();
  ref.onDispose(client.dispose);
  return client;
});

final radioControllerProvider = NotifierProvider<RadioController, RadioUiState>(
  RadioController.new,
);

/// Sip stats straight from the native engine.
/// Full stats arrive ~1 Hz; audio levels arrive ~15 Hz as partials (codec="")
/// so the meters update in real time.
final radioStatsProvider = StreamProvider<SipStats>((ref) {
  var last = SipStats();
  return ref.watch(radioSipProvider).stats.map((s) {
    if (s.codec.isEmpty && s.jitterMs == 0 && s.rttMs == 0) {
      // Audio-only partial: keep full stats, refresh live TX/RX levels.
      return last
          .copyWithAudioLevel(s.audioLevelDb)
          .copyWithRxAudioLevel(s.rxAudioLevelDb);
    }
    last = s;
    return s;
  });
});

/// Saved radio line (SIP preset), synced through the Go Mesh.
///
/// Remote provisioning is authoritative: the dashboard upserts
/// `broadcast_config.radio` for this device and the app applies it instantly
/// via Realtime (and once at startup via REST).
class SipPresetNotifier extends AsyncNotifier<SipPreset> {
  @override
  Future<SipPreset> build() async {
    final repo = ref.read(settingsRepositoryProvider);
    final mesh = ref.read(meshBroadcastConfigProvider);
    var preset = await repo.loadSipPreset();

    // Initial pull (also covers cold start before the realtime socket is up).
    try {
      final config = await mesh.fetchConfig();
      final remote = config?['radio'];
      if (remote is Map) {
        preset = SipPreset.fromJson({
          ...preset.toJson(),
          ...remote.cast<String, Object?>(),
        });
        await repo.saveSipPreset(preset);
        log(
          '[SipPreset] applied remote radio line ${preset.displayTarget} '
          'enabled=${preset.enabled}',
        );
      }
    } catch (e) {
      log('[SipPreset] remote fetch failed: $e');
    }

    // Live updates from the dashboard.
    var disposed = false;
    final sub = mesh.configChanges().listen((row) async {
      if (disposed) return;
      final radio = row['radio'];
      if (radio is! Map) return;
      final current = state.valueOrNull ?? preset;
      final merged = SipPreset.fromJson({
        ...current.toJson(),
        ...radio.cast<String, Object?>(),
      });
      if (mapEquals(current.toJson(), merged.toJson()) &&
          current.adminLocked == merged.adminLocked) {
        return;
      }

      preset = merged;
      await _applyRemote(merged);
    });
    ref.onDispose(() {
      disposed = true;
      sub.cancel();
    });

    return preset;
  }

  Future<void> save(SipPreset preset) async {
    state = AsyncData(preset);
    await ref.read(settingsRepositoryProvider).saveSipPreset(preset);
    log('[SipPreset] saved ${preset.displayTarget} enabled=${preset.enabled}');

    // Push to the mesh so the dashboard sees the device's current line.
    unawaited(ref.read(broadcastConfigBffProvider).saveRadio(preset.toJson()));
  }

  Future<void> _applyRemote(SipPreset merged) async {
    state = AsyncData(merged);
    await ref.read(settingsRepositoryProvider).saveSipPreset(merged);
    log(
      '[SipPreset] live remote update ${merged.displayTarget} '
      'enabled=${merged.enabled}',
    );
    await _applyToRadio(merged);
  }

  /// Re-registers (or tears down) the SIP line when the dashboard changes it.
  Future<void> _applyToRadio(SipPreset preset) async {
    final ctrl = ref.read(radioControllerProvider.notifier);
    final mode = ref.read(radioControllerProvider).mode;

    if (!preset.enabled) {
      if (mode == RadioMode.onAir || mode == RadioMode.connecting) {
        await ctrl.hangup();
      }
      if (mode == RadioMode.ready || mode == RadioMode.registering) {
        await ctrl.unregister();
      }
      return;
    }

    if (preset.isConfigured &&
        (mode == RadioMode.idle || mode == RadioMode.ready)) {
      await ctrl.register(preset);
    }
  }
}

final sipPresetProvider = AsyncNotifierProvider<SipPresetNotifier, SipPreset>(
  SipPresetNotifier.new,
);

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../broadcast/providers.dart' show settingsRepositoryProvider;
import '../models/sip_preset.dart';
import '../utils/log.dart';
import 'radio_controller.dart';

final radioSipProvider = Provider<SipClient>((ref) {
  final client = SipClient();
  ref.onDispose(client.dispose);
  return client;
});

final radioControllerProvider =
    NotifierProvider<RadioController, RadioUiState>(RadioController.new);

/// Sip stats straight from the native engine.
/// Full stats arrive ~1 Hz; audio levels arrive ~15 Hz as partials (codec="")
/// so the meters update in real time.
final radioStatsProvider = StreamProvider<SipStats>((ref) {
  var last = SipStats();
  return ref.watch(radioSipProvider).stats.map((s) {
    if (s.codec.isEmpty && s.jitterMs == 0 && s.rttMs == 0) {
      // Audio-only partial: keep full stats, refresh live TX/RX levels.
      return last.copyWithAudioLevel(s.audioLevelDb).copyWithRxAudioLevel(s.rxAudioLevelDb);
    }
    last = s;
    return s;
  });
});

/// Saved radio line (SIP preset).
class SipPresetNotifier extends AsyncNotifier<SipPreset> {
  @override
  Future<SipPreset> build() =>
      ref.read(settingsRepositoryProvider).loadSipPreset();

  Future<void> save(SipPreset preset) async {
    state = AsyncData(preset);
    await ref.read(settingsRepositoryProvider).saveSipPreset(preset);
    log('[SipPreset] saved ${preset.displayTarget} enabled=${preset.enabled}');
  }
}

final sipPresetProvider =
    AsyncNotifierProvider<SipPresetNotifier, SipPreset>(SipPresetNotifier.new);

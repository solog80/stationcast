import 'package:firebase_auth/firebase_auth.dart';

import '../models/destination_preset.dart';
import '../models/return_feed_config.dart';
import '../utils/log.dart';
import 'broadcast_config_bff.dart';

/// TV/broadcast config is stored as the `tv` object of the mesh
/// `broadcast_config` document and written through the BFF (Firebase ID token).
/// Reads prefer the mesh via the BFF; Realtime updates arrive through
/// [MeshBroadcastConfig].

String? get _uid => FirebaseAuth.instance.currentUser?.uid;

/// Raw `tv` object for the signed-in user (null when signed out/not set).
Future<Map<String, dynamic>?> fetchTvConfig() => BroadcastConfigBff().fetchTv();

/// Saves the full TV config (+ destinations) for the signed-in user.
Future<void> saveConfigToCloud(
  ReturnFeedConfig config, {
  List<DestinationPreset>? destinations,
}) async {
  if (_uid == null) return;
  try {
    final tv = <String, Object?>{
      'url': config.url,
      'latencyMs': config.latencyMs,
      'backend': config.backend.name,
      'autoplayOnLive': config.autoplayOnLive,
      'startMuted': config.startMuted,
      'srtPassphrase': config.srtPassphrase,
      'srtSenderMode': config.srtSenderMode.name,
      'maxHeight': config.maxHeight,
      'talkbackEnabled': config.talkbackEnabled,
      'talkbackUrl': config.talkbackUrl,
      'talkbackLatencyMs': config.talkbackLatencyMs,
      'talkbackPassphrase': config.talkbackPassphrase,
      'broadcasterId': config.broadcasterId,
      'broadcasterName': config.broadcasterName,
    };
    if (destinations != null) {
      tv['destinations'] = destinations.map((d) => d.toJson()).toList();
    }
    await BroadcastConfigBff().saveTv(tv);
    log('[SettingsSync] saved tv config to mesh');
  } catch (e) {
    log('[SettingsSync] save error: $e');
  }
}

/// Parses a `tv` object from the mesh into a [ReturnFeedConfig].
ReturnFeedConfig returnFeedConfigFromTv(Map<String, dynamic> tv) =>
    ReturnFeedConfig(
      url: tv['url'] as String? ?? 'srt://salttelevision.com:8011',
      latencyMs: (tv['latencyMs'] as num?)?.toInt() ?? 1000,
      backend: ReturnFeedBackend.values.firstWhere(
        (b) => b.name == tv['backend'],
        orElse: () => ReturnFeedBackend.auto,
      ),
      autoplayOnLive: tv['autoplayOnLive'] as bool? ?? true,
      startMuted: tv['startMuted'] as bool? ?? true,
      srtPassphrase: tv['srtPassphrase'] as String? ?? 'ffeMUNNYO11',
      srtSenderMode: SrtSenderMode.values.firstWhere(
        (m) => m.name == tv['srtSenderMode'],
        orElse: () => SrtSenderMode.caller,
      ),
      talkbackEnabled: tv['talkbackEnabled'] as bool? ?? false,
      talkbackUrl: tv['talkbackUrl'] as String? ?? '',
      talkbackLatencyMs: (tv['talkbackLatencyMs'] as num?)?.toInt() ?? 500,
      talkbackPassphrase: tv['talkbackPassphrase'] as String? ?? '',
      broadcasterId: tv['broadcasterId'] as String? ?? '',
      broadcasterName: tv['broadcasterName'] as String? ?? '',
      maxHeight: (tv['maxHeight'] as num?)?.toInt() ?? 0,
      lockedSections: _lockedSections(tv['locks']),
    );

/// Loads the TV config from the mesh. Returns null if not signed in or absent.
Future<ReturnFeedConfig?> loadConfigFromCloud() async {
  if (_uid == null) return null;
  try {
    final tv = await fetchTvConfig();
    if (tv == null) return null;
    return returnFeedConfigFromTv(tv);
  } on FirebaseAuthException {
    return null;
  } catch (e) {
    log('[SettingsSync] load error: $e');
    return null;
  }
}

List<String> _lockedSections(Object? locks) {
  if (locks is Map) {
    return locks.entries
        .where((e) => e.value == true && e.key is String)
        .map((e) => e.key as String)
        .toList();
  }
  if (locks is List) {
    return locks.whereType<String>().toList();
  }
  return const [];
}

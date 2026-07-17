import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/destination_preset.dart';
import '../models/return_feed_config.dart';
import '../utils/log.dart';

/// Returns the authenticated user's UID, or throws if not signed in.
String _uid() =>
    FirebaseAuth.instance.currentUser?.uid ??
    (throw Exception('Not signed in'));

/// Saves the full ReturnFeedConfig + destinations to Firestore under the user's UID.
Future<void> saveConfigToFirestore(
  ReturnFeedConfig config, {
  List<DestinationPreset>? destinations,
}) async {
  try {
    final data = <String, dynamic>{
      'url': config.url,
      'latencyMs': config.latencyMs,
      'backend': config.backend.name,
      'autoplayOnLive': config.autoplayOnLive,
      'startMuted': config.startMuted,
      'srtPassphrase': config.srtPassphrase,
      'srtSenderMode': config.srtSenderMode.name,
      'talkbackEnabled': config.talkbackEnabled,
      'talkbackUrl': config.talkbackUrl,
      'talkbackLatencyMs': config.talkbackLatencyMs,
      'talkbackPassphrase': config.talkbackPassphrase,
      'broadcasterId': config.broadcasterId,
      'broadcasterName': config.broadcasterName,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (destinations != null) {
      data['destinations'] = destinations
          .map(
            (d) => {
              'id': d.id,
              'name': d.name,
              'protocol': d.protocol.name,
              'host': d.host,
              'port': d.port,
              'streamId': d.streamId,
              'passphrase': d.passphrase,
              'latencyMs': d.latencyMs,
              'rtmpUrl': d.rtmpUrl,
              'streamKey': d.streamKey,
            },
          )
          .toList();
    }
    await FirebaseFirestore.instance
        .collection('broadcastConfig')
        .doc('user_${_uid()}')
        .set(data, SetOptions(merge: true));
    log('[SettingsSync] saved to Firestore');
  } catch (e) {
    log('[SettingsSync] save error: $e');
  }
}

/// Loads ReturnFeedConfig from Firestore. Returns null if not found or not signed in.
Future<ReturnFeedConfig?> loadConfigFromFirestore() async {
  try {
    final doc = await FirebaseFirestore.instance
        .collection('broadcastConfig')
        .doc('user_${_uid()}')
        .get();
    if (!doc.exists) return null;

    final data = doc.data()!;
    return ReturnFeedConfig(
      url: data['url'] as String? ?? 'srt://salttelevision.com:8011',
      latencyMs: (data['latencyMs'] as num?)?.toInt() ?? 1000,
      backend: ReturnFeedBackend.values.firstWhere(
        (b) => b.name == data['backend'],
        orElse: () => ReturnFeedBackend.auto,
      ),
      autoplayOnLive: data['autoplayOnLive'] as bool? ?? true,
      startMuted: data['startMuted'] as bool? ?? true,
      srtPassphrase: data['srtPassphrase'] as String? ?? 'ffeMUNNYO11',
      srtSenderMode: SrtSenderMode.values.firstWhere(
        (m) => m.name == data['srtSenderMode'],
        orElse: () => SrtSenderMode.caller,
      ),
      talkbackEnabled: data['talkbackEnabled'] as bool? ?? false,
      talkbackUrl: data['talkbackUrl'] as String? ?? '',
      talkbackLatencyMs: (data['talkbackLatencyMs'] as num?)?.toInt() ?? 500,
      talkbackPassphrase: data['talkbackPassphrase'] as String? ?? '',
      broadcasterId: data['broadcasterId'] as String? ?? '',
      broadcasterName: data['broadcasterName'] as String? ?? '',
    );
  } on FirebaseAuthException {
    return null;
  } catch (e) {
    log('[SettingsSync] load error: $e');
    return null;
  }
}

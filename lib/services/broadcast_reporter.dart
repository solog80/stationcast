import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/log.dart';

final broadcastReporterProvider = Provider<BroadcastReporter>((ref) {
  final reporter = BroadcastReporter();
  ref.onDispose(() => reporter.dispose());
  return reporter;
});

class BroadcastReporter {
  BroadcastReporter();

  StreamSubscription<DocumentSnapshot>? _configSub;
  String? _listeningUid;

  /// Fired with the raw config map from Firestore whenever it changes remotely.
  void Function(Map<String, dynamic> config)? onConfigChanged;

  /// Ensure the Firestore config listener is active. Call on login and after auth changes.
  Future<void> ensureInit() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null && uid != _listeningUid) _listenConfig();
  }

  void _listenConfig() {
    _configSub?.cancel();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    log('[BroadcastReporter] _listenConfig uid=$uid');
    if (uid == null) return;
    _listeningUid = uid;

    _configSub = FirebaseFirestore.instance
        .collection('broadcastConfig')
        .doc('user_$uid')
        .snapshots()
        .listen((snapshot) {
      log('[BroadcastReporter] snapshot exists=${snapshot.exists}');
      if (!snapshot.exists || onConfigChanged == null) return;
      final data = snapshot.data() as Map<String, dynamic>;
      log('[BroadcastReporter] remote config updated, keys: ${data.keys.join(", ")}');
      onConfigChanged!(data);
    }, onError: (e) {
      log('[BroadcastReporter] config listener error: $e');
    });
  }

  Future<void> register(String broadcasterId, String broadcasterName) async {
    if (broadcasterId.isEmpty) return;
    await ensureInit();
    try {
      await FirebaseFirestore.instance
          .collection('broadcasts')
          .doc(broadcasterId)
          .set({
        'broadcasterName': broadcasterName.isNotEmpty ? broadcasterName : broadcasterId,
        'isLive': false,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      log('[BroadcastReporter] registered: $broadcasterId');
    } catch (e) {
      log('[BroadcastReporter] register error: $e');
    }
  }

  Future<void> reportStatus({
    required String broadcasterId,
    String broadcasterName = '',
    bool isLive = false,
    int uptime = 0,
    int bitrate = 0,
    double rttMs = 0.0,
    int packetsDropped = 0,
    String returnFeedUrl = '',
    bool talkbackActive = false,
    String streamUrl = '',
  }) async {
    if (broadcasterId.isEmpty) return;
    await ensureInit();
    try {
      await FirebaseFirestore.instance
          .collection('broadcasts')
          .doc(broadcasterId)
          .set({
        'broadcasterName': broadcasterName.isNotEmpty ? broadcasterName : broadcasterId,
        'isLive': isLive, 'uptime': uptime, 'bitrate': bitrate,
        'rttMs': rttMs, 'packetsDropped': packetsDropped,
        'returnFeedUrl': returnFeedUrl, 'talkbackActive': talkbackActive,
        'streamUrl': streamUrl, 'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      log('[BroadcastReporter] report error: $e');
    }
  }

  Future<void> uploadSnapshot(String broadcasterId, Uint8List jpegBytes) async {
    if (broadcasterId.isEmpty) return;
    await ensureInit();
    try {
      await FirebaseFirestore.instance
          .collection('broadcasts')
          .doc(broadcasterId)
          .set({'snapshot': base64Encode(jpegBytes)}, SetOptions(merge: true));
    } catch (e) {
      log('[BroadcastReporter] snapshot upload error: $e');
    }
  }

  void dispose() {
    _configSub?.cancel();
  }
}

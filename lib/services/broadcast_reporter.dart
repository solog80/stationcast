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

  /// Kept for call-site compatibility; config sync moved to the mesh-backed
  /// providers (ReturnFeedConfigNotifier / SipPresetNotifier).
  Future<void> ensureInit() async {}

  Future<void> register(String broadcasterId, String broadcasterName) async {
    if (broadcasterId.isEmpty) return;
    await ensureInit();
    try {
      await FirebaseFirestore.instance
          .collection('broadcasts')
          .doc(broadcasterId)
          .set({
            'broadcasterName': broadcasterName.isNotEmpty
                ? broadcasterName
                : broadcasterId,
            'uid': FirebaseAuth.instance.currentUser?.uid,
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
            'broadcasterName': broadcasterName.isNotEmpty
                ? broadcasterName
                : broadcasterId,
            'isLive': isLive,
            'uptime': uptime,
            'bitrate': bitrate,
            'rttMs': rttMs,
            'packetsDropped': packetsDropped,
            'returnFeedUrl': returnFeedUrl,
            'talkbackActive': talkbackActive,
            'streamUrl': streamUrl,
            'uid': FirebaseAuth.instance.currentUser?.uid,
            'lastSeen': FieldValue.serverTimestamp(),
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

  void dispose() {}
}

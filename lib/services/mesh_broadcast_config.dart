import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase/supabase.dart';

import '../utils/log.dart';

/// Go Mesh (Supabase) endpoint. The anon key is public by design and is the
/// same key the SaltMedia app uses; it is safe to ship in the binary.
const String _meshBaseUrl = 'https://edge.solofx.net';
const String _meshAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
    'eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzg3MzM2Mjk0LCJleHAiOjE5NDUwMTYyOTR9.'
    '9YCCl_oRCYHQIR3eAhUeLF-SiBqGIxaT9WqCS-YFtNw';

/// Read-only + Realtime access to `public.broadcast_config` for the signed-in
/// device. Writes go through the BFF (see `BroadcastConfigBff`) because anon
/// clients have SELECT-only RLS.
///
/// A single Realtime channel is shared by every provider that listens to config
/// changes (return feed, presets, encoder, recording, radio). Creating one
/// channel per provider with the same topic makes Phoenix reject/duplicate the
/// subscription, which is why only some updates appeared before.
class MeshBroadcastConfig {
  MeshBroadcastConfig({SupabaseClient? client})
    : _client = client ?? SupabaseClient(_meshBaseUrl, _meshAnonKey);

  final SupabaseClient _client;
  final _changes = StreamController<Map<String, dynamic>>.broadcast();
  RealtimeChannel? _channel;
  String? _channelUid;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// One-shot fetch of `{tv, radio}` for the signed-in user.
  Future<Map<String, dynamic>?> fetchConfig() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final rows = await _client
          .from('broadcast_config')
          .select('tv,radio')
          .eq('user_id', uid)
          .limit(1);
      if (rows.isNotEmpty) return rows.first.cast<String, dynamic>();
    } catch (e) {
      log('[MeshConfig] fetch error: $e');
    }
    return null;
  }

  /// Live stream of `{tv, radio, user_id, updated_at}` row changes. Shared by
  /// all subscribers; the underlying channel is created lazily once per uid.
  Stream<Map<String, dynamic>> configChanges() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    _ensureChannel(uid);
    return _changes.stream;
  }

  void _ensureChannel(String uid) {
    if (_channel != null && _channelUid == uid) return;

    final old = _channel;
    _channel = null;
    if (old != null) {
      _client.removeChannel(old);
    }

    _channelUid = uid;
    _channel = _client
        .channel('broadcast_config:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'broadcast_config',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            if (row.isNotEmpty && !_changes.isClosed) {
              _changes.add(row.cast<String, dynamic>());
            }
          },
        )
        .subscribe((status, error) {
          log(
            '[MeshConfig] realtime $status${error == null ? '' : ' error=$error'}',
          );
          if (status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut) {
            // Retry: drop and recreate on the next configChanges()/listen.
            final ch = _channel;
            _channel = null;
            _channelUid = null;
            if (ch != null) {
              _client.removeChannel(ch);
            }
          }
        });
  }

  Future<void> dispose() async {
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        await _client.removeChannel(ch);
      } catch (_) {}
    }
    await _changes.close();
    try {
      await _client.dispose();
    } catch (_) {}
  }
}

final meshBroadcastConfigProvider = Provider<MeshBroadcastConfig>((ref) {
  final config = MeshBroadcastConfig();
  ref.onDispose(config.dispose);
  return config;
});

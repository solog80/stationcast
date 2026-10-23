import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../utils/log.dart';

/// Authenticated client for writing broadcast config (TV + radio) through the
/// SaltMedia Dart BFF. The phone proves identity with its Firebase ID token;
/// the BFF stores the document in the mesh with a service-role key.
class BroadcastConfigBff {
  BroadcastConfigBff({String? baseUrl, http.Client? client})
    : _baseUrl = baseUrl ?? 'https://edge.solofx.net',
      _client = client ?? http.Client();

  final String _baseUrl;
  final http.Client _client;

  static const _endpoint = '/api/v1/bff/broadcast/config';

  Future<Map<String, String>?> _authHeaders() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return null;
      return {'Authorization': 'Bearer $token', 'Accept': 'application/json'};
    } catch (e) {
      log('[BffConfig] token error: $e');
      return null;
    }
  }

  /// Fetches `{tv, radio}` for the signed-in device.
  Future<Map<String, dynamic>?> fetchConfig() async {
    final headers = await _authHeaders();
    if (headers == null) return null;
    try {
      final res = await _client
          .get(Uri.parse('$_baseUrl$_endpoint'), headers: headers)
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        log('[BffConfig] fetch status ${res.statusCode}');
        return null;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'];
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return data.cast<String, dynamic>();
      return const {};
    } catch (e) {
      log('[BffConfig] fetch error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchTv() async {
    final config = await fetchConfig();
    final tv = config?['tv'];
    if (tv is Map<String, dynamic>) return tv;
    if (tv is Map) return tv.cast<String, dynamic>();
    return null;
  }

  Future<bool> saveTv(Map<String, Object?> tv) => _save({'tv': tv});

  Future<bool> saveRadio(Map<String, Object?> radio) => _save({'radio': radio});

  Future<bool> _save(Map<String, Object?> patch) async {
    final headers = await _authHeaders();
    if (headers == null) return false;
    try {
      final res = await _client
          .post(
            Uri.parse('$_baseUrl$_endpoint'),
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode(patch),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        log('[BffConfig] save status ${res.statusCode}: ${res.body}');
        return false;
      }
      log('[BffConfig] saved ${patch.keys.join(',')} remotely');
      return true;
    } catch (e) {
      log('[BffConfig] save error: $e');
      return false;
    }
  }
}

final broadcastConfigBffProvider = Provider<BroadcastConfigBff>(
  (ref) => BroadcastConfigBff(),
);

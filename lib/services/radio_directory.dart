import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../utils/log.dart';

/// A presenter currently registered in the studio conference.
class RadioPresenter {
  const RadioPresenter({
    required this.name,
    required this.extension,
    required this.callerId,
    required this.muted,
    this.avatarUrl = '',
  });

  final String name;
  final String extension;
  final String callerId;
  final bool muted;
  final String avatarUrl;

  String get displayName => name.isNotEmpty ? name : extension;

  factory RadioPresenter.fromJson(Map<String, dynamic> json) => RadioPresenter(
    name: '${json['name'] ?? ''}',
    extension: '${json['extension'] ?? ''}',
    callerId: '${json['callerId'] ?? ''}',
    muted: json['muted'] == true,
    avatarUrl: '${json['avatarUrl'] ?? ''}',
  );
}

/// Reads the live presenter directory from the BFF using the signed-in
/// Firebase identity. Returns an empty list when unavailable so the radio page
/// never changes layout just because the directory is offline.
class RadioDirectory {
  static const String _endpoint =
      'https://edge.solofx.net/api/v1/bff/radio/presenters';

  Future<List<RadioPresenter>> fetch() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const [];
    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return const [];
      final res = await http
          .get(
            Uri.parse(_endpoint),
            headers: {
              'authorization': 'Bearer $token',
              'accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        log('[RadioDirectory] status ${res.statusCode}');
        return const [];
      }
      final body = jsonDecode(res.body);
      if (body is! Map) return const [];
      final list = body['presenters'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((e) => RadioPresenter.fromJson(e.cast<String, dynamic>()))
          .where((p) => p.displayName.isNotEmpty)
          .toList();
    } catch (e) {
      log('[RadioDirectory] fetch error: $e');
      return const [];
    }
  }
}

final radioDirectoryProvider = Provider<RadioDirectory>(
  (ref) => RadioDirectory(),
);

/// Lightweight polling provider: refreshes every 3 seconds while the radio
/// screen is visible. Auto-disposes when the screen is closed.
final radioPresentersProvider =
    StreamProvider.autoDispose<List<RadioPresenter>>((ref) {
      final directory = ref.watch(radioDirectoryProvider);
      final controller = StreamController<List<RadioPresenter>>();
      Timer? timer;
      var loading = false;

      Future<void> load() async {
        if (loading || controller.isClosed) return;
        loading = true;
        try {
          final presenters = await directory.fetch();
          if (!controller.isClosed) controller.add(presenters);
        } catch (_) {
          if (!controller.isClosed) controller.add(const []);
        } finally {
          loading = false;
        }
      }

      unawaited(load());
      timer = Timer.periodic(const Duration(seconds: 3), (_) => load());

      ref.onDispose(() {
        timer?.cancel();
        controller.close();
      });

      return controller.stream;
    });

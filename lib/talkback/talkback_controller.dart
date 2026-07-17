import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../broadcast/providers.dart';
import '../models/return_feed_config.dart';
import '../utils/log.dart';

class TalkbackState {
  const TalkbackState({
    this.enabled = false,
    this.connected = false,
    this.active = false,
  });

  final bool enabled;
  final bool connected;
  final bool active;

  TalkbackState copyWith({
    bool? enabled,
    bool? connected,
    bool? active,
  }) =>
      TalkbackState(
        enabled: enabled ?? this.enabled,
        connected: connected ?? this.connected,
        active: active ?? this.active,
      );
}

class TalkbackController extends Notifier<TalkbackState> {
  @override
  TalkbackState build() {
    ref.onDispose(() {
      _stop();
    });
    return const TalkbackState();
  }

  Future<void> start() async {
    final config = ref.read(returnFeedConfigProvider).valueOrNull;
    if (config == null) return;
    final url = _buildUrl(config);
    log('[Talkback] start() url=$url');
    try {
      await ref.read(broadcastPluginProvider).talkbackStart(url);
      state = state.copyWith(enabled: true, connected: true, active: true);
      log('[Talkback] player started');
    } catch (e) {
      log('[Talkback] start failed: $e');
    }
  }

  String _buildUrl(ReturnFeedConfig config) {
    final url = config.talkbackUrl;
    if (!url.startsWith('srt://')) return url;

    final uri = Uri.parse(url);
    final params = <String, String>{
      ...uri.queryParameters,
      'latency': '${config.talkbackLatencyMs}',
      'mode': 'caller',
      'transtype': 'live',
      'connect_timeout': '10000',
    };
    if (config.talkbackPassphrase.isNotEmpty) {
      params['passphrase'] = config.talkbackPassphrase;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port,
      queryParameters: params,
    ).toString();
  }

  Future<void> stop() async {
    await _stop();
    state = state.copyWith(enabled: false, connected: false, active: false);
  }

  Future<void> _stop() async {
    try {
      await ref.read(broadcastPluginProvider).talkbackStop();
    } catch (_) {}
  }
}

final talkbackControllerProvider =
    NotifierProvider<TalkbackController, TalkbackState>(TalkbackController.new);

final talkbackAutoProvider = Provider<void>((ref) {
  final isLive = ref.watch(broadcastControllerProvider.select((s) => s.isLive));
  final config = ref.watch(returnFeedConfigProvider).valueOrNull;

  if (isLive && config != null && config.talkbackEnabled && config.talkbackUrl.isNotEmpty) {
    ref.read(talkbackControllerProvider.notifier).start();
  } else if (!isLive) {
    ref.read(talkbackControllerProvider.notifier).stop();
  }

  return;
});

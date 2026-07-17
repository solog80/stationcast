import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:station_broadcast/station_broadcast.dart';

import '../models/return_feed_config.dart';
import '../utils/log.dart';
import 'return_feed_player.dart';

class SrtPlatformReturnFeedPlayer implements ReturnFeedPlayer {
  SrtPlatformReturnFeedPlayer() {
    _state.add(ReturnFeedState.idle);
  }

  final _state = StreamController<ReturnFeedState>.broadcast();
  String? _url;
  Timer? _playbackCheckTimer;
  bool _muted = true;

  @override
  Future<void> open(
    String url, {
    int latencyMs = 500,
    bool muted = true,
    String? srtPassphrase,
    SrtSenderMode srtSenderMode = SrtSenderMode.caller,
  }) async {
    log('[SrtPlatform] open() called with url: $url');
    _url = _buildSrtUrl(url, latencyMs, srtPassphrase, srtSenderMode);
    _muted = muted;
    log('[SrtPlatform] Built SRT URL: $_url');
    _state.add(ReturnFeedState.buffering);

    // Monitor playback state with a timeout
    _playbackCheckTimer?.cancel();
    _playbackCheckTimer = Timer(const Duration(seconds: 5), () {
      log('[SrtPlatform] 5s timeout, assuming playback is ready');
      _state.add(ReturnFeedState.playing);
    });
  }

  String _buildSrtUrl(
    String baseUrl,
    int latencyMs,
    String? passphrase,
    SrtSenderMode senderMode,
  ) {
    if (!baseUrl.startsWith('srt://')) return baseUrl;

    final uri = Uri.parse(baseUrl);
    final params = <String, String>{
      ...uri.queryParameters,
      'latency': '$latencyMs',
      'mode': senderMode.name,
      'transtype': 'live',
      'connect_timeout': '30000',
    };
    if (passphrase != null && passphrase.isNotEmpty) {
      params['passphrase'] = passphrase;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port,
      queryParameters: params,
    ).toString();
  }

  @override
  Future<void> stop() async {
    _playbackCheckTimer?.cancel();
    _state.add(ReturnFeedState.idle);
  }

  @override
  Future<void> setMuted(bool muted) async {
    log('[SrtPlatform] setMuted: $muted');
    _muted = muted;
  }

  @override
  Widget buildVideo(BuildContext context) {
    final url = _url;
    if (url == null) return const SizedBox.shrink();
    log('[SrtPlatform] buildVideo called, returning NativeSrtPlayer');
    return NativeSrtPlayer(url: url, muted: _muted);
  }

  @override
  Stream<ReturnFeedState> get stateStream => _state.stream;

  @override
  Future<void> dispose() async {
    _playbackCheckTimer?.cancel();
    await _state.close();
  }
}

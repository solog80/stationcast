import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../broadcast/providers.dart';
import '../models/return_feed_config.dart';
import '../utils/log.dart';
import 'return_feed_player.dart';
import 'srt_platform_return_feed_player.dart';

class ReturnFeedUiState {
  const ReturnFeedUiState({
    this.visible = false,
    this.muted = true,
    this.playback = ReturnFeedState.idle,
    this.activeBackend,
  });

  final bool visible;
  final bool muted;
  final ReturnFeedState playback;
  final ReturnFeedBackend? activeBackend;

  ReturnFeedUiState copyWith({
    bool? visible,
    bool? muted,
    ReturnFeedState? playback,
    ReturnFeedBackend? activeBackend,
  }) => ReturnFeedUiState(
    visible: visible ?? this.visible,
    muted: muted ?? this.muted,
    playback: playback ?? this.playback,
    activeBackend: activeBackend ?? this.activeBackend,
  );
}

/// Owns the return feed player instance and the floating window state.
///
/// With backend `auto`, playback starts on media_kit and falls back to VLC
/// automatically if the stream errors within the probe window (libmpv builds
/// without SRT fail fast on the protocol).
class ReturnFeedController extends Notifier<ReturnFeedUiState> {
  ReturnFeedPlayer? _player;
  StreamSubscription<ReturnFeedState>? _stateSub;
  Timer? _autoFallbackTimer;
  bool _triedFallback = false;

  ReturnFeedPlayer? get player => _player;

  @override
  ReturnFeedUiState build() {
    ref.onDispose(() {
      _stateSub?.cancel();
      _autoFallbackTimer?.cancel();
      _player?.dispose();
    });
    return const ReturnFeedUiState();
  }

  Future<void> show() async {
    log('[ReturnFeedController] show() called');
    final config = await ref.read(returnFeedConfigProvider.future);
    if (config.url.isEmpty) {
      log('[ReturnFeedController] config.url is empty, showing idle state');
      state = state.copyWith(visible: true, playback: ReturnFeedState.idle);
      return;
    }
    _triedFallback = false;
    state = state.copyWith(visible: true, muted: config.startMuted);
    final backend = _resolveBackendForPlatform(config.backend);
    await _startWith(backend, config);
  }

  Future<void> hide() async {
    state = state.copyWith(visible: false, playback: ReturnFeedState.idle);
    await _teardownPlayer();
  }

  Future<void> toggleMute() async {
    final next = !state.muted;
    await _player?.setMuted(next);
    state = state.copyWith(muted: next);
  }

  Future<void> _startWith(
    ReturnFeedBackend backend,
    ReturnFeedConfig config,
  ) async {
    log('[ReturnFeedController] _startWith() called with backend: $backend');
    await _teardownPlayer();
    final player = switch (backend) {
      ReturnFeedBackend.srtPlatform => SrtPlatformReturnFeedPlayer(),
      _ => SrtPlatformReturnFeedPlayer(),
    };
    _player = player;
    state = state.copyWith(
      activeBackend: backend,
      playback: ReturnFeedState.buffering,
    );

    final useVlcFallback =
        config.backend == ReturnFeedBackend.auto &&
        backend == ReturnFeedBackend.mediaKit &&
        !Platform.isAndroid;

    _stateSub = player.stateStream.listen((playback) async {
      log('[ReturnFeedController] player state changed to: $playback');
      state = state.copyWith(playback: playback);
      if (playback == ReturnFeedState.error &&
          useVlcFallback &&
          !_triedFallback) {
        log('[ReturnFeedController] media_kit error, falling back to VLC');
        _triedFallback = true;
        await _startWith(ReturnFeedBackend.vlc, config);
      }
      if (playback == ReturnFeedState.playing) {
        log(
          '[ReturnFeedController] playback started, canceling fallback timer',
        );
        _autoFallbackTimer?.cancel();
      }
    });

    if (useVlcFallback) {
      _autoFallbackTimer?.cancel();
      log(
        '[ReturnFeedController] Starting 8-second fallback timer for media_kit',
      );
      _autoFallbackTimer = Timer(const Duration(seconds: 8), () async {
        if (state.playback != ReturnFeedState.playing && !_triedFallback) {
          log(
            '[ReturnFeedController] 8-second timer expired without playback, falling back to VLC',
          );
          _triedFallback = true;
          await _startWith(ReturnFeedBackend.vlc, config);
        }
      });
    }

    // Safety timeout: if VLC fallback doesn't reach playing within 30s, error.
    if (backend == ReturnFeedBackend.vlc) {
      _autoFallbackTimer?.cancel();
      _autoFallbackTimer = Timer(const Duration(seconds: 30), () {
        if (state.playback != ReturnFeedState.playing) {
          log('[ReturnFeedController] VLC fallback timed out after 30s');
          state = state.copyWith(
            playback: ReturnFeedState.error,
            visible: true,
            activeBackend: ReturnFeedBackend.vlc,
          );
        }
      });
    }

    await player.open(
      config.url,
      latencyMs: config.latencyMs,
      muted: state.muted,
      srtPassphrase: config.srtPassphrase,
      srtSenderMode: config.srtSenderMode,
    );
  }

  ReturnFeedBackend _resolveBackend(ReturnFeedBackend configured) =>
      configured == ReturnFeedBackend.auto
      ? ReturnFeedBackend.srtPlatform
      : configured;

  /// Resolves backend considering platform constraints.
  /// On mobile, uses the native platform player (ExoPlayer on Android, AVPlayer on iOS).
  ReturnFeedBackend _resolveBackendForPlatform(ReturnFeedBackend configured) {
    if (Platform.isAndroid || Platform.isIOS) {
      log('[ReturnFeedController] Mobile platform: using SRT platform player');
      return ReturnFeedBackend.srtPlatform;
    }
    return _resolveBackend(configured);
  }

  Future<void> _teardownPlayer() async {
    _autoFallbackTimer?.cancel();
    await _stateSub?.cancel();
    _stateSub = null;
    final old = _player;
    _player = null;
    await old?.dispose();
  }
}

final returnFeedControllerProvider =
    NotifierProvider<ReturnFeedController, ReturnFeedUiState>(
      ReturnFeedController.new,
    );

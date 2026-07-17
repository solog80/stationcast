import 'package:flutter/widgets.dart';

import '../models/return_feed_config.dart';

enum ReturnFeedState { idle, buffering, playing, error }

/// Playback backend abstraction for the station return feed.
///
/// Two implementations exist because SRT playback support differs between
/// engines: media_kit (libmpv) and VLC (libVLC). The backend is chosen in
/// settings; `auto` prefers media_kit and falls back to VLC on error.
abstract class ReturnFeedPlayer {
  Future<void> open(
    String url, {
    int latencyMs = 500,
    bool muted = true,
    String? srtPassphrase,
    SrtSenderMode srtSenderMode = SrtSenderMode.caller,
  });

  Future<void> stop();

  Future<void> setMuted(bool muted);

  /// The video surface for embedding in the floating window.
  Widget buildVideo(BuildContext context);

  Stream<ReturnFeedState> get stateStream;

  Future<void> dispose();
}

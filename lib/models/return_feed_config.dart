enum ReturnFeedBackend { auto, mediaKit, vlc, srtPlatform }

enum SrtSenderMode { caller, listener, rendezvous }

/// Settings for the station's return feed shown in the floating window.
class ReturnFeedConfig {
  const ReturnFeedConfig({
    this.url = 'srt://salttelevision.com:8011',
    this.latencyMs = 1000,
    this.backend = ReturnFeedBackend.auto,
    this.autoplayOnLive = true,
    this.startMuted = true,
    this.srtPassphrase = 'ffeMUNNYO11',
    this.srtSenderMode = SrtSenderMode.caller,
    this.talkbackEnabled = false,
    this.talkbackUrl = '',
    this.talkbackLatencyMs = 500,
    this.talkbackPassphrase = '',
    this.broadcasterId = '',
    this.broadcasterName = '',
  });

  final String url;
  final int latencyMs;
  final ReturnFeedBackend backend;
  final bool autoplayOnLive;
  final bool startMuted;
  final String srtPassphrase;
  final SrtSenderMode srtSenderMode;

  // Talkback (audio intercom)
  final bool talkbackEnabled;
  final String talkbackUrl;
  final int talkbackLatencyMs;
  final String talkbackPassphrase;

  // Broadcaster identity
  final String broadcasterId;
  final String broadcasterName;

  ReturnFeedConfig copyWith({
    String? url,
    int? latencyMs,
    ReturnFeedBackend? backend,
    bool? autoplayOnLive,
    bool? startMuted,
    String? srtPassphrase,
    SrtSenderMode? srtSenderMode,
    bool? talkbackEnabled,
    String? talkbackUrl,
    int? talkbackLatencyMs,
    String? talkbackPassphrase,
    String? broadcasterId,
    String? broadcasterName,
  }) =>
      ReturnFeedConfig(
        url: url ?? this.url,
        latencyMs: latencyMs ?? this.latencyMs,
        backend: backend ?? this.backend,
        autoplayOnLive: autoplayOnLive ?? this.autoplayOnLive,
        startMuted: startMuted ?? this.startMuted,
        srtPassphrase: srtPassphrase ?? this.srtPassphrase,
        srtSenderMode: srtSenderMode ?? this.srtSenderMode,
        talkbackEnabled: talkbackEnabled ?? this.talkbackEnabled,
        talkbackUrl: talkbackUrl ?? this.talkbackUrl,
        talkbackLatencyMs: talkbackLatencyMs ?? this.talkbackLatencyMs,
        talkbackPassphrase: talkbackPassphrase ?? this.talkbackPassphrase,
        broadcasterId: broadcasterId ?? this.broadcasterId,
        broadcasterName: broadcasterName ?? this.broadcasterName,
      );

  Map<String, Object?> toJson() => {
        'url': url,
        'latencyMs': latencyMs,
        'backend': backend.name,
        'autoplayOnLive': autoplayOnLive,
        'startMuted': startMuted,
        'srtPassphrase': srtPassphrase,
        'srtSenderMode': srtSenderMode.name,
        'talkbackEnabled': talkbackEnabled,
        'talkbackUrl': talkbackUrl,
        'talkbackLatencyMs': talkbackLatencyMs,
        'talkbackPassphrase': talkbackPassphrase,
        'broadcasterId': broadcasterId,
        'broadcasterName': broadcasterName,
      };

  static ReturnFeedConfig fromJson(Map<String, Object?> json) => ReturnFeedConfig(
        url: json['url'] as String? ?? 'srt://salttelevision.com:8011',
        latencyMs: (json['latencyMs'] as num?)?.toInt() ?? 1000,
        backend: ReturnFeedBackend.values.firstWhere(
          (b) => b.name == json['backend'],
          orElse: () => ReturnFeedBackend.auto,
        ),
        autoplayOnLive: json['autoplayOnLive'] as bool? ?? true,
        startMuted: json['startMuted'] as bool? ?? true,
        srtPassphrase: json['srtPassphrase'] as String? ?? 'ffeMUNNYO11',
        srtSenderMode: SrtSenderMode.values.firstWhere(
          (m) => m.name == json['srtSenderMode'],
          orElse: () => SrtSenderMode.caller,
        ),
        talkbackEnabled: json['talkbackEnabled'] as bool? ?? false,
        talkbackUrl: json['talkbackUrl'] as String? ?? '',
        talkbackLatencyMs: (json['talkbackLatencyMs'] as num?)?.toInt() ?? 500,
        talkbackPassphrase: json['talkbackPassphrase'] as String? ?? '',
        broadcasterId: json['broadcasterId'] as String? ?? '',
        broadcasterName: json['broadcasterName'] as String? ?? '',
      );
}

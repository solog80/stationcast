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
    this.maxHeight = 0,
    this.talkbackEnabled = false,
    this.talkbackUrl = '',
    this.talkbackLatencyMs = 500,
    this.talkbackPassphrase = '',
    this.broadcasterId = '',
    this.broadcasterName = '',
    this.lockedSections = const <String>[],
  });

  final String url;
  final int latencyMs;
  final ReturnFeedBackend backend;
  final bool autoplayOnLive;
  final bool startMuted;
  final String srtPassphrase;
  final SrtSenderMode srtSenderMode;

  /// Cap the return-feed video resolution (max height in px). 0 = full/auto.
  /// Lower = less decode/render work (cooler) when the source offers renditions.
  final int maxHeight;

  // Talkback (audio intercom)
  final bool talkbackEnabled;
  final String talkbackUrl;
  final int talkbackLatencyMs;
  final String talkbackPassphrase;

  // Broadcaster identity
  final String broadcasterId;
  final String broadcasterName;

  /// Settings sections the station admin has locked ("admin only"):
  /// broadcaster, returnFeed, talkback, encoder, recording, destinations.
  /// Devices apply remote values and the BFF rejects device writes to them.
  final List<String> lockedSections;

  ReturnFeedConfig copyWith({
    String? url,
    int? latencyMs,
    ReturnFeedBackend? backend,
    bool? autoplayOnLive,
    bool? startMuted,
    String? srtPassphrase,
    SrtSenderMode? srtSenderMode,
    int? maxHeight,
    bool? talkbackEnabled,
    String? talkbackUrl,
    int? talkbackLatencyMs,
    String? talkbackPassphrase,
    String? broadcasterId,
    String? broadcasterName,
    List<String>? lockedSections,
  }) => ReturnFeedConfig(
    url: url ?? this.url,
    latencyMs: latencyMs ?? this.latencyMs,
    backend: backend ?? this.backend,
    autoplayOnLive: autoplayOnLive ?? this.autoplayOnLive,
    startMuted: startMuted ?? this.startMuted,
    srtPassphrase: srtPassphrase ?? this.srtPassphrase,
    srtSenderMode: srtSenderMode ?? this.srtSenderMode,
    maxHeight: maxHeight ?? this.maxHeight,
    talkbackEnabled: talkbackEnabled ?? this.talkbackEnabled,
    talkbackUrl: talkbackUrl ?? this.talkbackUrl,
    talkbackLatencyMs: talkbackLatencyMs ?? this.talkbackLatencyMs,
    talkbackPassphrase: talkbackPassphrase ?? this.talkbackPassphrase,
    broadcasterId: broadcasterId ?? this.broadcasterId,
    broadcasterName: broadcasterName ?? this.broadcasterName,
    lockedSections: lockedSections ?? this.lockedSections,
  );

  Map<String, Object?> toJson() => {
    'url': url,
    'latencyMs': latencyMs,
    'backend': backend.name,
    'autoplayOnLive': autoplayOnLive,
    'startMuted': startMuted,
    'srtPassphrase': srtPassphrase,
    'srtSenderMode': srtSenderMode.name,
    'maxHeight': maxHeight,
    'talkbackEnabled': talkbackEnabled,
    'talkbackUrl': talkbackUrl,
    'talkbackLatencyMs': talkbackLatencyMs,
    'talkbackPassphrase': talkbackPassphrase,
    'broadcasterId': broadcasterId,
    'broadcasterName': broadcasterName,
  };

  static ReturnFeedConfig fromJson(Map<String, Object?> json) =>
      ReturnFeedConfig(
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
        maxHeight: (json['maxHeight'] as num?)?.toInt() ?? 0,
        talkbackEnabled: json['talkbackEnabled'] as bool? ?? false,
        talkbackUrl: json['talkbackUrl'] as String? ?? '',
        talkbackLatencyMs: (json['talkbackLatencyMs'] as num?)?.toInt() ?? 500,
        talkbackPassphrase: json['talkbackPassphrase'] as String? ?? '',
        broadcasterId: json['broadcasterId'] as String? ?? '',
        broadcasterName: json['broadcasterName'] as String? ?? '',
      );
}

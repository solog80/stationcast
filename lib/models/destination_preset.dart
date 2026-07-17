import 'package:station_broadcast/station_broadcast.dart';

/// A saved stream destination (the station's ingest point).
class DestinationPreset {
  const DestinationPreset({
    required this.id,
    required this.name,
    this.protocol = BroadcastProtocol.srt,
    this.host = '',
    this.port = 8890,
    this.streamId = '',
    this.passphrase = '',
    this.latencyMs = 200,
    this.rtmpUrl = '',
    this.streamKey = '',
  });

  final String id;
  final String name;
  final BroadcastProtocol protocol;
  final String host;
  final int port;
  final String streamId;
  final String passphrase;
  final int latencyMs;
  final String rtmpUrl;
  final String streamKey;

  DestinationConfig toDestinationConfig() {
    switch (protocol) {
      case BroadcastProtocol.srt:
        return DestinationConfig.srt(
          host: host,
          port: port,
          streamId: streamId.isEmpty ? null : streamId,
          passphrase: passphrase.isEmpty ? null : passphrase,
          latencyMs: latencyMs,
        );
      case BroadcastProtocol.rtmp:
        return DestinationConfig.rtmp(rtmpUrl: rtmpUrl, streamKey: streamKey);
    }
  }

  DestinationPreset copyWith({
    String? name,
    BroadcastProtocol? protocol,
    String? host,
    int? port,
    String? streamId,
    String? passphrase,
    int? latencyMs,
    String? rtmpUrl,
    String? streamKey,
  }) =>
      DestinationPreset(
        id: id,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        host: host ?? this.host,
        port: port ?? this.port,
        streamId: streamId ?? this.streamId,
        passphrase: passphrase ?? this.passphrase,
        latencyMs: latencyMs ?? this.latencyMs,
        rtmpUrl: rtmpUrl ?? this.rtmpUrl,
        streamKey: streamKey ?? this.streamKey,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'host': host,
        'port': port,
        'streamId': streamId,
        'passphrase': passphrase,
        'latencyMs': latencyMs,
        'rtmpUrl': rtmpUrl,
        'streamKey': streamKey,
      };

  static DestinationPreset fromJson(Map<String, Object?> json) => DestinationPreset(
        id: '${json['id']}',
        name: '${json['name']}',
        protocol: BroadcastProtocol.values.firstWhere(
          (p) => p.name == json['protocol'],
          orElse: () => BroadcastProtocol.srt,
        ),
        host: json['host'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 8890,
        streamId: json['streamId'] as String? ?? '',
        passphrase: json['passphrase'] as String? ?? '',
        latencyMs: (json['latencyMs'] as num?)?.toInt() ?? 200,
        rtmpUrl: json['rtmpUrl'] as String? ?? '',
        streamKey: json['streamKey'] as String? ?? '',
      );

  /// Short human-readable target, e.g. `srt://10.0.0.5:8890`.
  String get displayTarget => protocol == BroadcastProtocol.srt
      ? 'srt://$host:$port'
      : rtmpUrl;
}

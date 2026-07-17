/// Video codec choices supported by both native engines.
enum BroadcastVideoCodec { h264, hevc }

/// Transport protocol for the outgoing stream.
enum BroadcastProtocol { srt, rtmp }

/// Encoder configuration applied when the engine is initialized (and
/// re-applied on [StationBroadcast.initialize] calls).
class EncoderConfig {
  const EncoderConfig({
    this.width = 1280,
    this.height = 720,
    this.fps = 30,
    this.videoBitrateBps = 3000000,
    this.audioBitrateBps = 128000,
    this.codec = BroadcastVideoCodec.h264,
  });

  final int width;
  final int height;
  final int fps;
  final int videoBitrateBps;
  final int audioBitrateBps;
  final BroadcastVideoCodec codec;

  Map<String, Object?> toMap() => {
        'width': width,
        'height': height,
        'fps': fps,
        'videoBitrateBps': videoBitrateBps,
        'audioBitrateBps': audioBitrateBps,
        'codec': codec.name,
      };
}

/// Where to send the stream. For SRT the URL is assembled natively from the
/// individual parts; for RTMP provide [rtmpUrl] + [streamKey].
class DestinationConfig {
  const DestinationConfig.srt({
    required this.host,
    required this.port,
    this.streamId,
    this.passphrase,
    this.latencyMs = 200,
  })  : protocol = BroadcastProtocol.srt,
        rtmpUrl = null,
        streamKey = null;

  const DestinationConfig.rtmp({
    required this.rtmpUrl,
    required this.streamKey,
  })  : protocol = BroadcastProtocol.rtmp,
        host = null,
        port = null,
        streamId = null,
        passphrase = null,
        latencyMs = 0;

  final BroadcastProtocol protocol;
  final String? host;
  final int? port;
  final String? streamId;
  final String? passphrase;
  final int latencyMs;
  final String? rtmpUrl;
  final String? streamKey;

  Map<String, Object?> toMap() => {
        'protocol': protocol.name,
        'host': host,
        'port': port,
        'streamId': streamId,
        'passphrase': passphrase,
        'latencyMs': latencyMs,
        'rtmpUrl': rtmpUrl,
        'streamKey': streamKey,
      };
}

/// An available audio capture device (built-in mic, headset, USB, bluetooth).
class BroadcastAudioDevice {
  const BroadcastAudioDevice({required this.id, required this.name, required this.type});

  final String id;
  final String name;

  /// Native type label, e.g. builtin / wired / bluetooth / usb / unknown.
  final String type;

  static BroadcastAudioDevice fromMap(Map<Object?, Object?> map) => BroadcastAudioDevice(
        id: '${map['id']}',
        name: '${map['name']}',
        type: '${map['type']}',
      );
}

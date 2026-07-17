/// Connection lifecycle as reported by the native engine.
enum BroadcastConnectionState { idle, connecting, live, reconnecting, failed, stopped }

/// A state-change or error event from the native engine.
class BroadcastEvent {
  const BroadcastEvent({required this.state, this.message});

  final BroadcastConnectionState state;
  final String? message;

  static BroadcastEvent fromMap(Map<Object?, Object?> map) {
    final raw = '${map['state']}';
    final state = BroadcastConnectionState.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => BroadcastConnectionState.idle,
    );
    return BroadcastEvent(state: state, message: map['message'] as String?);
  }

  @override
  String toString() => 'BroadcastEvent($state${message == null ? '' : ', $message'})';
}

/// Link/encoder statistics, emitted roughly once per second while streaming.
/// Audio levels are emitted with every tick (and also while idle/previewing).
class StreamStats {
  const StreamStats({
    this.bitrateBps = 0,
    this.rttMs = 0,
    this.packetsSent = 0,
    this.packetsDropped = 0,
    this.packetsRetransmitted = 0,
    this.bandwidthMbps = 0,
    this.audioLevelDb = const [-60.0, -60.0],
  });

  final int bitrateBps;
  final double rttMs;
  final int packetsSent;
  final int packetsDropped;
  final int packetsRetransmitted;
  final double bandwidthMbps;

  /// Per-channel level in dBFS, typically [-60, 0]. Mono devices report one
  /// channel duplicated.
  final List<double> audioLevelDb;

  static StreamStats fromMap(Map<Object?, Object?> map) => StreamStats(
        bitrateBps: (map['bitrateBps'] as num?)?.toInt() ?? 0,
        rttMs: (map['rttMs'] as num?)?.toDouble() ?? 0,
        packetsSent: (map['packetsSent'] as num?)?.toInt() ?? 0,
        packetsDropped: (map['packetsDropped'] as num?)?.toInt() ?? 0,
        packetsRetransmitted: (map['packetsRetransmitted'] as num?)?.toInt() ?? 0,
        bandwidthMbps: (map['bandwidthMbps'] as num?)?.toDouble() ?? 0,
        audioLevelDb: _parseAudioLevel(map['audioLevelDb']),
      );

  StreamStats copyWithAudioLevel(List<double> level) => StreamStats(
    bitrateBps: bitrateBps, rttMs: rttMs, packetsSent: packetsSent,
    packetsDropped: packetsDropped, packetsRetransmitted: packetsRetransmitted,
    bandwidthMbps: bandwidthMbps, audioLevelDb: level,
  );

  static List<double> _parseAudioLevel(Object? value) {
    if (value is List) {
      return value.map((e) => (e as num).toDouble()).toList();
    }
    return const [-60.0, -60.0];
  }
}

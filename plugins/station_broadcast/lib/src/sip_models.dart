/// Transport/call lifecycle for the SIP (EBU 3326) radio engine.
///
/// Mirrors [BroadcastConnectionState] semantics where possible so the radio
/// page reads like the TV page: idle → registering → registered → ringing →
/// live, with failed/ended terminal states.
enum SipConnectionState {
  idle,
  registering,
  registered,
  ringing,
  connecting,
  live,
  failed,
  ended,
}

/// Config for registering to the station's SIP registrar (Asterisk).
class SipConfig {
  const SipConfig({
    this.registrarHost = '',
    this.registrarPort = 5060,
    this.username = '',
    this.password = '',
    this.extension = '',
    this.codec = 'g722',
    this.autoAnswer = false,
  });

  /// Registrar/relay host, e.g. `158.220.126.145`.
  final String registrarHost;
  final int registrarPort;

  /// Auth username + password as provisioned on Asterisk (e.g. `field`).
  final String username;
  final String password;

  /// Local extension / AOR, e.g. `field`.
  final String extension;

  /// Preferred audio codec: `g722`, `opus`, `pcmu`, `pcma`.
  final String codec;

  /// Automatically answer inbound calls (studio → field).
  final bool autoAnswer;

  SipConfig copyWith({
    String? registrarHost,
    int? registrarPort,
    String? username,
    String? password,
    String? extension,
    String? codec,
    bool? autoAnswer,
  }) => SipConfig(
    registrarHost: registrarHost ?? this.registrarHost,
    registrarPort: registrarPort ?? this.registrarPort,
    username: username ?? this.username,
    password: password ?? this.password,
    extension: extension ?? this.extension,
    codec: codec ?? this.codec,
    autoAnswer: autoAnswer ?? this.autoAnswer,
  );

  Map<String, Object?> toMap() => {
    'registrarHost': registrarHost,
    'registrarPort': registrarPort,
    'username': username,
    'password': password,
    'extension': extension,
    'codec': codec,
    'autoAnswer': autoAnswer,
  };

  static SipConfig fromMap(Map<String, Object?> map) => SipConfig(
    registrarHost: '${map['registrarHost'] ?? ''}',
    registrarPort: (map['registrarPort'] as num?)?.toInt() ?? 5060,
    username: '${map['username'] ?? ''}',
    password: '${map['password'] ?? ''}',
    extension: '${map['extension'] ?? ''}',
    codec: '${map['codec'] ?? 'g722'}',
    autoAnswer: map['autoAnswer'] as bool? ?? false,
  );
}

/// A call/registration event from the native engine.
class SipCallEvent {
  const SipCallEvent({required this.state, this.peer, this.message});

  final SipConnectionState state;

  /// Peer display name / URI for ringing or live calls, e.g. "STUDIO LIVE".
  final String? peer;
  final String? message;

  static SipCallEvent fromMap(Map<Object?, Object?> map) => SipCallEvent(
    state: SipConnectionState.values.firstWhere(
      (s) => s.name == '${map['state']}',
      orElse: () => SipConnectionState.idle,
    ),
    peer: map['peer'] as String?,
    message: map['message'] as String?,
  );

  @override
  String toString() => 'SipCallEvent($state${peer == null ? '' : ', peer: $peer'})';
}

/// Per-call quality + audio-level stats (~1 Hz while in a call).
class SipStats {
  const SipStats({
    this.jitterMs = 0,
    this.rttMs = 0,
    this.packetsLost = 0,
    this.txPayloadBytes = 0,
    this.rxPayloadBytes = 0,
    this.codec = '',
    this.audioLevelDb = const [-60.0, -60.0],
    this.rxAudioLevelDb = const [-60.0, -60.0],
  });

  final double jitterMs;
  final double rttMs;
  final int packetsLost;
  final int txPayloadBytes;
  final int rxPayloadBytes;
  final String codec;

  /// TX = local mic level in dBFS.
  final List<double> audioLevelDb;

  /// RX = return-feed level from the studio, in dBFS.
  final List<double> rxAudioLevelDb;

  static SipStats fromMap(Map<Object?, Object?> map) => SipStats(
    jitterMs: (map['jitterMs'] as num?)?.toDouble() ?? 0,
    rttMs: (map['rttMs'] as num?)?.toDouble() ?? 0,
    packetsLost: (map['packetsLost'] as num?)?.toInt() ?? 0,
    txPayloadBytes: (map['txPayloadBytes'] as num?)?.toInt() ?? 0,
    rxPayloadBytes: (map['rxPayloadBytes'] as num?)?.toInt() ?? 0,
    codec: '${map['codec'] ?? ''}',
    audioLevelDb: _parseAudioLevel(map['audioLevelDb']),
    rxAudioLevelDb: _parseAudioLevel(map['rxAudioLevelDb']),
  );

  SipStats copyWithAudioLevel(List<double> level) => SipStats(
    jitterMs: jitterMs,
    rttMs: rttMs,
    packetsLost: packetsLost,
    txPayloadBytes: txPayloadBytes,
    rxPayloadBytes: rxPayloadBytes,
    codec: codec,
    audioLevelDb: level,
    rxAudioLevelDb: rxAudioLevelDb,
  );

  SipStats copyWithRxAudioLevel(List<double> level) => SipStats(
    jitterMs: jitterMs,
    rttMs: rttMs,
    packetsLost: packetsLost,
    txPayloadBytes: txPayloadBytes,
    rxPayloadBytes: rxPayloadBytes,
    codec: codec,
    audioLevelDb: audioLevelDb,
    rxAudioLevelDb: level,
  );

  static List<double> _parseAudioLevel(Object? value) {
    if (value is List) {
      return value.map((e) => (e as num).toDouble()).toList();
    }
    return const [-60.0, -60.0];
  }
}

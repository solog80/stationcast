/// Saved SIP/EBU 3326 registration preset (the studio's radio line).
///
/// Mirrors [DestinationPreset] so radio lines are editable/persisted the same
/// way SRT/RTMP destinations are.
class SipPreset {
  const SipPreset({
    this.id = 'sip_default',
    this.name = 'Studio Radio',
    this.registrarHost = '',
    this.registrarPort = 5060,
    this.username = '',
    this.password = '',
    this.extension = '',
    this.codec = 'g722',
    this.autoAnswer = false,
    this.enabled = false,
  });

  final String id;
  final String name;
  final String registrarHost;
  final int registrarPort;
  final String username;
  final String password;
  final String extension;

  /// Preferred codec label used in the offer: G.722 / Opus / G.711.
  final String codec;

  /// Auto-answer inbound studio calls.
  final bool autoAnswer;

  /// Whether the radio line is configured and should register on app start.
  final bool enabled;

  bool get isConfigured =>
      registrarHost.isNotEmpty && username.isNotEmpty && extension.isNotEmpty;

  SipPreset copyWith({
    String? id,
    String? name,
    String? registrarHost,
    int? registrarPort,
    String? username,
    String? password,
    String? extension,
    String? codec,
    bool? autoAnswer,
    bool? enabled,
  }) => SipPreset(
    id: id ?? this.id,
    name: name ?? this.name,
    registrarHost: registrarHost ?? this.registrarHost,
    registrarPort: registrarPort ?? this.registrarPort,
    username: username ?? this.username,
    password: password ?? this.password,
    extension: extension ?? this.extension,
    codec: codec ?? this.codec,
    autoAnswer: autoAnswer ?? this.autoAnswer,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'registrarHost': registrarHost,
    'registrarPort': registrarPort,
    'username': username,
    'password': password,
    'extension': extension,
    'codec': codec,
    'autoAnswer': autoAnswer,
    'enabled': enabled,
  };

  static SipPreset fromJson(Map<String, Object?> json) => SipPreset(
    id: '${json['id'] ?? 'sip_default'}',
    name: '${json['name'] ?? 'Studio Radio'}',
    registrarHost: '${json['registrarHost'] ?? ''}',
    registrarPort: (json['registrarPort'] as num?)?.toInt() ?? 5060,
    username: '${json['username'] ?? ''}',
    password: '${json['password'] ?? ''}',
    extension: '${json['extension'] ?? ''}',
    codec: '${json['codec'] ?? 'g722'}',
    autoAnswer: json['autoAnswer'] as bool? ?? false,
    enabled: json['enabled'] as bool? ?? false,
  );

  /// Short display target, e.g. `field@158.220.126.145:5060`.
  String get displayTarget =>
      '$username@$registrarHost:${registrarPort == 5060 ? '' : '$registrarPort'}';
}

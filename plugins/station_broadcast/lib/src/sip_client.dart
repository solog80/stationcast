import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sip_models.dart';

/// Dart facade over the native SIP/EBU 3326 radio engine (PJSIP).
///
/// Lifecycle: [initialize] → [register] → engine calls in (or is dialed) →
/// [accept] / [decline] / [hangup] → [unregister] / [dispose].
///
/// Kept separate from [StationBroadcast] because SIP is audio-only and must
/// not fight the video engine for the microphone.
class SipClient {
  SipClient({
    @visibleForTesting MethodChannel? methodChannel,
    @visibleForTesting EventChannel? eventsChannel,
    @visibleForTesting EventChannel? statsChannel,
  })  : _channel = methodChannel ?? const MethodChannel('tv.stationcast/sip'),
        _events = eventsChannel ?? const EventChannel('tv.stationcast/sip/events'),
        _stats = statsChannel ?? const EventChannel('tv.stationcast/sip/stats');

  final MethodChannel _channel;
  final EventChannel _events;
  final EventChannel _stats;

  Stream<SipCallEvent>? _eventStream;
  Stream<SipStats>? _statsStream;

  /// Call-state events. Broadcast stream; safe to listen multiple times.
  Stream<SipCallEvent> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map((e) => SipCallEvent.fromMap(e as Map<Object?, Object?>));

  /// Per-call stats while in a call (~1 Hz).
  Stream<SipStats> get stats => _statsStream ??= _stats
      .receiveBroadcastStream()
      .map((e) => SipStats.fromMap(e as Map<Object?, Object?>));

  /// Create the PJSIP engine (no registration yet).
  Future<void> initialize() => _channel.invokeMethod('initialize');

  /// Register to the configured registrar so the studio can call the field.
  Future<void> register(SipConfig config) =>
      _channel.invokeMethod('register', config.toMap());

  /// Accept an inbound call (engine already answered at the SIP level).
  Future<void> accept() => _channel.invokeMethod('accept');

  /// Decline an inbound call.
  Future<void> decline() => _channel.invokeMethod('decline');

  /// Hang up an active call.
  Future<void> hangup() => _channel.invokeMethod('hangup');

  /// Place an outbound call to [target] (extension or SIP URI), e.g. `100`.
  Future<void> dial(String target) =>
      _channel.invokeMethod('dial', {'target': target});

  /// Stop listening and tear down registration.
  Future<void> unregister() => _channel.invokeMethod('unregister');

  /// Destroy the engine. Call once on app exit / radio leave.
  Future<void> dispose() => _channel.invokeMethod('dispose');
}

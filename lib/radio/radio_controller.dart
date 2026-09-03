import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:station_broadcast/station_broadcast.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/sip_preset.dart';
import '../utils/log.dart';
import 'providers.dart';

enum RadioMode { idle, registering, ready, incoming, connecting, onAir, failed }

class RadioUiState {
  const RadioUiState({
    this.mode = RadioMode.idle,
    this.preset = const SipPreset(),
    this.initialized = false,
    this.peer = '',
    this.codec = '',
    this.errorMessage,
    this.connectedSince,
    this.ringingSince,
  });

  final RadioMode mode;
  final SipPreset preset;
  final bool initialized;

  /// Remote display name during ringing/on-air ("STUDIO LIVE").
  final String peer;

  /// Negotiated codec label while on air (G.722 / Opus / G.711).
  final String codec;

  final String? errorMessage;
  final DateTime? connectedSince;
  final DateTime? ringingSince;

  bool get isOnAir => mode == RadioMode.onAir;
  bool get isBusy =>
      mode == RadioMode.registering ||
      mode == RadioMode.connecting ||
      mode == RadioMode.incoming;
  bool get isReady => mode == RadioMode.ready;

  RadioUiState copyWith({
    RadioMode? mode,
    SipPreset? preset,
    bool? initialized,
    String? peer,
    String? codec,
    String? errorMessage,
    bool clearError = false,
    DateTime? connectedSince,
    bool clearConnectedSince = false,
    DateTime? ringingSince,
    bool clearRingingSince = false,
  }) => RadioUiState(
    mode: mode ?? this.mode,
    preset: preset ?? this.preset,
    initialized: initialized ?? this.initialized,
    peer: peer ?? this.peer,
    codec: codec ?? this.codec,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    connectedSince: clearConnectedSince ? null : (connectedSince ?? this.connectedSince),
    ringingSince: clearRingingSince ? null : (ringingSince ?? this.ringingSince),
  );
}

/// Orchestrates the native PJSIP radio engine: registers to the studio
/// registrar and handles the studio calling in (EBU 3326 contribution).
class RadioController extends Notifier<RadioUiState> {
  StreamSubscription<SipCallEvent>? _eventSub;
  StreamSubscription<SipStats>? _statsSub;
  bool _dialPending = false;

  SipClient get _sip => ref.read(radioSipProvider);

  @override
  RadioUiState build() {
    _eventSub?.cancel();
    _eventSub = _sip.events.listen(_onSipEvent);
    _statsSub?.cancel();
    _statsSub = _sip.stats.listen((s) {
      if (s.codec.isNotEmpty) {
        state = state.copyWith(codec: s.codec.toUpperCase());
      }
    });
    ref.onDispose(() {
      _eventSub?.cancel();
      _statsSub?.cancel();
    });
    return const RadioUiState();
  }

  Future<void> initialize(SipPreset preset) async {
    try {
      await _sip.initialize();
    } catch (e) {
      log('[Radio] initialize failed: $e');
    }
    state = state.copyWith(
      preset: preset,
      initialized: true,
      mode: RadioMode.idle,
    );
  }

  /// Register to the studio registrar so the console can call the field.
  Future<void> register(SipPreset preset) async {
    // Guard: ignore if a register/unregister is already in flight or we're
    // already registered - prevents the UI from stacking native account
    // creates (which pjsua2 aborts on).
    if (state.mode == RadioMode.registering ||
        state.mode == RadioMode.connecting ||
        state.mode == RadioMode.incoming) {
      return;
    }
    if (!preset.isConfigured) {
      state = state.copyWith(
        mode: RadioMode.failed,
        errorMessage: 'Radio line not configured - check settings',
      );
      return;
    }
    state = state.copyWith(
      preset: preset,
      mode: RadioMode.registering,
      clearError: true,
      clearConnectedSince: true,
      clearRingingSince: true,
      peer: '',
    );
    try {
      await _sip.register(_toSipConfig(preset));
    } catch (e) {
      state = state.copyWith(
        mode: RadioMode.failed,
        errorMessage: _friendly(e.toString()),
      );
    }
  }

  /// Take an inbound call from the studio.
  Future<void> accept() async {
    if (state.mode != RadioMode.incoming) {
      return;
    }
    state = state.copyWith(mode: RadioMode.connecting);
    try {
      await _sip.accept();
    } catch (e) {
      state = state.copyWith(
        mode: RadioMode.failed,
        errorMessage: _friendly(e.toString()),
      );
    }
  }

  Future<void> decline() async {
    try {
      await _sip.decline();
    } catch (_) {}
    state = state.copyWith(
      mode: RadioMode.ready,
      clearRingingSince: true,
      peer: '',
    );
  }

  Future<void> hangup() async {
    try {
      await _sip.hangup();
    } catch (_) {}
    state = state.copyWith(
      mode: RadioMode.ready,
      clearConnectedSince: true,
      clearRingingSince: true,
      peer: '',
      codec: '',
    );
  }

  /// Field phone -> studio: dial the studio's extension (the Comrex).
  /// If not registered yet, register and dial once the registration lands.
  Future<void> callStudio([SipPreset? preset]) async {
    final p = preset ?? state.preset;
    if (state.mode == RadioMode.onAir ||
        state.mode == RadioMode.connecting ||
        state.mode == RadioMode.incoming ||
        state.mode == RadioMode.registering) {
      return;
    }
    if (state.mode != RadioMode.ready) {
      _dialPending = true;
      await register(p);
      return;
    }
    await _dialStudio();
  }

  Future<void> _dialStudio() async {
    state = state.copyWith(mode: RadioMode.connecting, peer: 'Studio');
    try {
      // Dial the fully-qualified studio URI so PJSIP doesn't misparse a bare
      // extension (which it would send to 's@...'). Extension 100 = Comrex.
      final preset = state.preset;
      final host = preset.registrarHost;
      await _sip.dial('sip:100@$host');
    } catch (e) {
      state = state.copyWith(
        mode: RadioMode.failed,
        errorMessage: _friendly(e.toString()),
      );
    }
  }

  Future<void> unregister() async {
    try {
      await _sip.unregister();
    } catch (_) {}
    await WakelockPlus.disable();
    state = state.copyWith(
      mode: RadioMode.idle,
      clearConnectedSince: true,
      clearRingingSince: true,
      peer: '',
      codec: '',
    );
  }

  void _onSipEvent(SipCallEvent event) {
    switch (event.state) {
      case SipConnectionState.registering:
        state = state.copyWith(mode: RadioMode.registering);
      case SipConnectionState.registered:
        state = state.copyWith(
          mode: RadioMode.ready,
          clearError: true,
          clearConnectedSince: true,
          clearRingingSince: true,
        );
        if (_dialPending) {
          _dialPending = false;
          _dialStudio();
        }
      case SipConnectionState.ringing:
        state = state.copyWith(
          mode: RadioMode.incoming,
          peer: event.peer ?? '',
          ringingSince: state.ringingSince ?? DateTime.now(),
        );
        if (state.preset.autoAnswer) accept();
      case SipConnectionState.connecting:
        state = state.copyWith(mode: RadioMode.connecting);
      case SipConnectionState.live:
        WakelockPlus.enable();
        state = state.copyWith(
          mode: RadioMode.onAir,
          connectedSince: state.connectedSince ?? DateTime.now(),
          clearRingingSince: true,
          clearError: true,
          peer: event.peer ?? state.peer,
        );
      case SipConnectionState.ended:
        WakelockPlus.disable();
        state = state.copyWith(
          mode: RadioMode.ready,
          clearConnectedSince: true,
          clearRingingSince: true,
          peer: '',
          codec: '',
        );
      case SipConnectionState.failed:
        WakelockPlus.disable();
        state = state.copyWith(
          mode: RadioMode.failed,
          errorMessage: _friendly(event.message ?? ''),
        );
      case SipConnectionState.idle:
        state = state.copyWith(mode: RadioMode.idle);
    }
  }

  SipConfig _toSipConfig(SipPreset preset) => SipConfig(
    registrarHost: preset.registrarHost,
    registrarPort: preset.registrarPort,
    username: preset.username,
    password: preset.password,
    extension: preset.extension,
    codec: preset.codec,
    autoAnswer: preset.autoAnswer,
  );

  String _friendly(String technical) {
    final lower = technical.toLowerCase();
    if (lower.contains('auth') ||
        lower.contains('401') ||
        lower.contains('403')) {
      return 'Registration rejected - check radio credentials';
    } else if (lower.contains('timeout') || lower.contains('network')) {
      return 'Can\'t reach the radio server - check connection';
    } else if (lower.contains('permission') || lower.contains('mic')) {
      return 'Microphone access needed for radio';
    } else if (technical.isEmpty) {
      return 'Radio link failed - try again';
    }
    return technical;
  }
}

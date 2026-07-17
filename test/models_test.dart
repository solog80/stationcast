import 'package:flutter_test/flutter_test.dart';
import 'package:station_broadcast/station_broadcast.dart';
import 'package:station_cast/models/destination_preset.dart';
import 'package:station_cast/models/encoder_settings.dart';
import 'package:station_cast/models/return_feed_config.dart';

void main() {
  group('DestinationPreset', () {
    test('SRT preset round-trips through JSON', () {
      const preset = DestinationPreset(
        id: '1',
        name: 'Station A',
        host: '10.0.0.5',
        port: 8890,
        streamId: 'publish:cam1',
        passphrase: 'secret',
        latencyMs: 300,
      );
      final restored = DestinationPreset.fromJson(preset.toJson());
      expect(restored.name, 'Station A');
      expect(restored.protocol, BroadcastProtocol.srt);
      expect(restored.host, '10.0.0.5');
      expect(restored.port, 8890);
      expect(restored.streamId, 'publish:cam1');
      expect(restored.passphrase, 'secret');
      expect(restored.latencyMs, 300);
    });

    test('maps to SRT DestinationConfig with empty optionals as null', () {
      const preset = DestinationPreset(id: '1', name: 'A', host: 'h', port: 1);
      final config = preset.toDestinationConfig();
      expect(config.protocol, BroadcastProtocol.srt);
      expect(config.streamId, isNull);
      expect(config.passphrase, isNull);
      final map = config.toMap();
      expect(map['host'], 'h');
      expect(map['protocol'], 'srt');
    });

    test('RTMP preset maps to RTMP config', () {
      const preset = DestinationPreset(
        id: '2',
        name: 'B',
        protocol: BroadcastProtocol.rtmp,
        rtmpUrl: 'rtmp://x/live',
        streamKey: 'key',
      );
      final config = preset.toDestinationConfig();
      expect(config.protocol, BroadcastProtocol.rtmp);
      expect(config.rtmpUrl, 'rtmp://x/live');
      expect(config.streamKey, 'key');
    });
  });

  group('EncoderSettings', () {
    test('round-trips through JSON and maps to EncoderConfig', () {
      const settings = EncoderSettings(
        resolution: ResolutionPreset.fullHd,
        fps: 50,
        videoBitrateBps: 6000000,
        codec: BroadcastVideoCodec.hevc,
      );
      final restored = EncoderSettings.fromJson(settings.toJson());
      expect(restored.resolution, ResolutionPreset.fullHd);
      expect(restored.fps, 50);
      expect(restored.codec, BroadcastVideoCodec.hevc);

      final config = restored.toEncoderConfig();
      expect(config.width, 1920);
      expect(config.height, 1080);
      expect(config.toMap()['codec'], 'hevc');
    });
  });

  group('ReturnFeedConfig', () {
    test('round-trips and defaults to muted', () {
      const config = ReturnFeedConfig(url: 'srt://h:1?streamid=read:x');
      final restored = ReturnFeedConfig.fromJson(config.toJson());
      expect(restored.url, 'srt://h:1?streamid=read:x');
      expect(restored.startMuted, isTrue);
      expect(restored.backend, ReturnFeedBackend.auto);
    });
  });

  group('Plugin event/stat parsing', () {
    test('BroadcastEvent parses known and unknown states', () {
      expect(
        BroadcastEvent.fromMap(const {'state': 'live', 'message': null}).state,
        BroadcastConnectionState.live,
      );
      expect(
        BroadcastEvent.fromMap(const {'state': 'bogus'}).state,
        BroadcastConnectionState.idle,
      );
    });

    test('StreamStats parses full and partial maps', () {
      final full = StreamStats.fromMap(const {
        'bitrateBps': 2500000,
        'rttMs': 42.5,
        'packetsSent': 1000,
        'packetsDropped': 3,
        'packetsRetransmitted': 7,
        'bandwidthMbps': 18.0,
        'audioLevelDb': [-12.0, -14.5],
      });
      expect(full.bitrateBps, 2500000);
      expect(full.rttMs, 42.5);
      expect(full.packetsDropped, 3);
      expect(full.audioLevelDb, [-12.0, -14.5]);

      final partial = StreamStats.fromMap(const {'bitrateBps': 100});
      expect(partial.bitrateBps, 100);
      expect(partial.rttMs, 0);
      expect(partial.audioLevelDb, [-60.0, -60.0]);
    });
  });
}

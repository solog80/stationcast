import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:station_broadcast/station_broadcast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tv.stationcast/broadcast');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getMaxZoom') return 8.0;
      if (call.method == 'getAudioDevices') {
        return [
          {'id': '3', 'name': 'Headset', 'type': 'wired'},
        ];
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('initialize sends encoder config map', () async {
    final plugin = StationBroadcast();
    await plugin.initialize(const EncoderConfig(width: 1920, height: 1080));
    expect(calls.single.method, 'initialize');
    final args = (calls.single.arguments as Map).cast<String, Object?>();
    expect(args['width'], 1920);
    expect(args['codec'], 'h264');
  });

  test('startStream sends SRT destination parts', () async {
    final plugin = StationBroadcast();
    await plugin.startStream(const DestinationConfig.srt(
      host: 'example.com',
      port: 8890,
      streamId: 'publish:cam',
      latencyMs: 250,
    ));
    final args = (calls.single.arguments as Map).cast<String, Object?>();
    expect(args['protocol'], 'srt');
    expect(args['host'], 'example.com');
    expect(args['port'], 8890);
    expect(args['latencyMs'], 250);
  });

  test('getMaxZoom and getAudioDevices parse results', () async {
    final plugin = StationBroadcast();
    expect(await plugin.getMaxZoom(), 8.0);
    final devices = await plugin.getAudioDevices();
    expect(devices.single.name, 'Headset');
    expect(devices.single.type, 'wired');
  });
}

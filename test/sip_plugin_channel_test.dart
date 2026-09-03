import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:station_broadcast/station_broadcast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tv.stationcast/sip');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('register sends SIP config map', () async {
    final sip = SipClient();
    await sip.register(const SipConfig(
      registrarHost: '158.220.126.145',
      registrarPort: 5060,
      username: 'field',
      password: 'secret',
      extension: 'field',
      codec: 'g722',
    ));
    expect(calls.single.method, 'register');
    final args = (calls.single.arguments as Map).cast<String, Object?>();
    expect(args['registrarHost'], '158.220.126.145');
    expect(args['username'], 'field');
    expect(args['codec'], 'g722');
  });

  test('accept/decline/hangup/unregister hit the right methods', () async {
    final sip = SipClient();
    await sip.accept();
    await sip.decline();
    await sip.hangup();
    await sip.unregister();
    await sip.dispose();
    expect(
      calls.map((c) => c.method),
      ['accept', 'decline', 'hangup', 'unregister', 'dispose'],
    );
  });

  test('SipCallEvent parses known states and peers', () {
    final ev = SipCallEvent.fromMap({
      'state': 'ringing',
      'peer': 'STUDIO LIVE',
    });
    expect(ev.state, SipConnectionState.ringing);
    expect(ev.peer, 'STUDIO LIVE');
    expect(
      SipCallEvent.fromMap(const {'state': 'bogus'}).state,
      SipConnectionState.idle,
    );
  });

  test('SipStats parses full and partial maps', () {
    final full = SipStats.fromMap({
      'jitterMs': 2.5,
      'rttMs': 18.0,
      'packetsLost': 4,
      'codec': 'g722',
      'audioLevelDb': [-12.0, -20.0],
    });
    expect(full.jitterMs, 2.5);
    expect(full.rttMs, 18.0);
    expect(full.codec, 'g722');
    expect(full.audioLevelDb, [-12.0, -20.0]);

    final partial = SipStats.fromMap(const {'audioLevelDb': [-40.0]});
    expect(partial.jitterMs, 0);
    expect(partial.audioLevelDb, [-40.0]);
    expect(
      SipStats.fromMap(const {}).copyWithAudioLevel([-6.0]).audioLevelDb,
      [-6.0],
    );
  });
}

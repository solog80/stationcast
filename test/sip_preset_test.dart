import 'package:flutter_test/flutter_test.dart';
import 'package:station_cast/models/sip_preset.dart';

void main() {
  test('SipPreset defaults to an empty disabled line', () {
    const p = SipPreset();
    expect(p.enabled, false);
    expect(p.isConfigured, false);
    expect(p.codec, 'g722');
    expect(p.registrarPort, 5060);
  });

  test('isConfigured requires registrar + username + extension', () {
    const partial = SipPreset(registrarHost: '1.2.3.4', username: 'field');
    expect(partial.isConfigured, false);
    const full = SipPreset(
      registrarHost: '158.220.126.145',
      username: 'field',
      extension: 'field',
    );
    expect(full.isConfigured, true);
  });

  test('SipPreset round-trips through JSON', () {
    const p = SipPreset(
      name: 'Studio Radio',
      registrarHost: '158.220.126.145',
      username: 'field',
      password: 'secret',
      extension: 'field',
      codec: 'g722',
      autoAnswer: true,
      enabled: true,
    );
    final restored = SipPreset.fromJson(p.toJson());
    expect(restored.name, p.name);
    expect(restored.registrarHost, p.registrarHost);
    expect(restored.registrarPort, p.registrarPort);
    expect(restored.autoAnswer, true);
    expect(restored.enabled, true);
  });

  test('displayTarget renders host:port', () {
    const p = SipPreset(
      registrarHost: '158.220.126.145',
      username: 'field',
      extension: 'field',
    );
    expect(p.displayTarget, 'field@158.220.126.145:');
    const withPort = SipPreset(
      registrarHost: '10.0.0.1',
      registrarPort: 5090,
      username: 'alice',
      extension: 'alice',
    );
    expect(withPort.displayTarget, 'alice@10.0.0.1:5090');
  });
}

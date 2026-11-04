import 'package:ai_chatbot/server/relay_protocol.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4);
  const outer = RelayIdentity('outer', 'outer-test-key', []);
  const inner = RelayIdentity('inner', 'inner-test-key', ['outer']);
  RelayIdentity resolve(String id) => id == 'outer' ? outer : id == 'inner' ? inner : throw BridgeException('Unknown relay');
  Map<String, dynamic> payload() => {'kind': 'request', 'method': 'POST', 'path': '/v1/messages', 'key': 'client-test-key', 'body': 'original'};
  RelayEnvelope chain() => RelayEnvelope(payload()).append(inner, now: now, nonce: 'one').append(outer, now: now, nonce: 'two');
  test('two relays preserve the signed path and reject replays', () {
    final envelope = chain();
    final replay = RelayReplayCache();
    envelope.verify(resolve, replay, now: now);
    expect(envelope.path, ['outer', 'inner']);
    expect(() => envelope.verify(resolve, replay, now: now), throwsA(isA<BridgeException>()));
  });
  test('changing the body, client key, destination, hop order or route is rejected', () {
    for (final field in ['body', 'key', 'path']) {
      final j = chain().toJson();
      (j['payload'] as Map)[field] = 'tampered';
      expect(() => RelayEnvelope.fromJson(j).verify(resolve, RelayReplayCache(), now: now), throwsA(isA<BridgeException>()));
    }
    final j = chain().toJson(); (j['hops'] as List).removeAt(0);
    expect(() => RelayEnvelope.fromJson(j).verify(resolve, RelayReplayCache(), now: now), throwsA(isA<BridgeException>()));
    final bypass = RelayEnvelope(payload()).append(inner, now: now);
    expect(() => bypass.verify(resolve, RelayReplayCache(), now: now), throwsA(isA<BridgeException>()));
  });
  test('expired requests and forwarding loops are rejected', () {
    expect(() => chain().verify(resolve, RelayReplayCache(), now: now.add(const Duration(minutes: 6))), throwsA(isA<BridgeException>()));
    expect(() => chain().append(outer), throwsA(isA<BridgeException>()));
  });
}

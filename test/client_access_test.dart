import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('allowlists distinguish unrestricted from deny all and expire at the deadline', () {
    final now = DateTime.utc(2026, 11, 4);
    final policy = ClientAccess(expires: now.add(const Duration(hours: 1)),
      models: {'a'}, services: {'chat'});
    policy.check(stopped: false, model: 'a', service: 'chat', now: now);
    expect(() => policy.check(stopped: false, model: 'b', now: now), throwsA(isA<BridgeException>()));
    expect(() => policy.check(stopped: false, service: 'codex', now: now), throwsA(isA<BridgeException>()));
    expect(() => policy.check(stopped: false, now: policy.expires), throwsA(isA<BridgeException>()));
    expect(() => policy.check(stopped: true, now: now), throwsA(isA<BridgeException>()));
    final restored = ClientAccess.fromJson(policy.toJson());
    expect(restored.models, {'a'});
    expect(restored.services, {'chat'});
    restored.models = {};
    expect(() => restored.check(stopped: false, model: 'a', now: now), throwsA(isA<BridgeException>()));
  });

  test('concurrent token reservations fail closed and settlement is idempotent', () {
    final usage = ClientUsage();
    final policy = ClientAccess(tokensPerDay: 20000, requestsPerDay: 2);
    final first = usage.reserve(policy, input: {'prompt': 'Hi'});
    expect(first.maxOutputTokens, greaterThan(0));
    expect(usage.tokens, 20000);
    expect(() => usage.reserve(policy, input: {}), throwsA(isA<BridgeException>()));
    first.settle(inputTokens: 10, outputTokens: 20);
    first.settle(inputTokens: 1, outputTokens: 1);
    expect(usage.tokens, 30);
    final second = usage.reserve(policy, input: {});
    second.settle();
    expect(usage.tokens, 20000, reason: 'unknown usage must not give free requests');
    expect(() => usage.reserve(policy, input: {}), throwsA(isA<BridgeException>()));
  });

  test('daily reset and a late settlement cannot corrupt the new day', () {
    final usage = ClientUsage();
    final policy = ClientAccess(tokensPerDay: 20000);
    final first = usage.reserve(policy, input: {}, now: DateTime(2026, 11, 4));
    usage.refresh(DateTime(2026, 11, 5));
    first.settle(inputTokens: 10, outputTokens: 20);
    expect(usage.tokens, 0);
    expect(usage.requests, 0);
    expect(ClientUsage.fromJson(usage.toJson()).day, usage.day);
  });

  test('legacy keys retain compatibility while policy and counters persist', () {
    final device = PairedDevice.fromJson({'id': 'x', 'name': 'PC', 'key': 'test',
      'created': DateTime(2026).toIso8601String()});
    expect(device.access.approved, isTrue);
    device.access.models = {};
    device.accessRequested = true;
    device.usage.reserve(device.access);
    final restored = PairedDevice.fromJson(device.toJson());
    expect(restored.access.models, isEmpty);
    expect(restored.accessRequested, isTrue);
    expect(restored.usage.requests, 1);
  });
}

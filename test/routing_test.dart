import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/named_sources.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

class RouteFake extends LlmProvider {
  RouteFake(ProviderSettings settings, String key, this.run)
    : super(settings: settings, apiKey: key);
  final Stream<ChatDelta> Function(String, ChatRequest) run;
  @override
  Stream<ChatDelta> streamChat(ChatRequest request) => run(apiKey, request);
  @override
  Future<List<String>> listModels() async => ['first', 'second'];
}

void main() {
  late Directory dir;
  late Storage storage;
  late NamedSources catalog;
  late Stream<ChatDelta> Function(String, ChatRequest) run;
  final attempts = <String>[];
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('routing');
    storage = await Storage.openAt(dir.path);
    catalog = NamedSources(
      storage,
      factory: (s, key) => RouteFake(s, key, (k, r) {
        attempts.add('$k/${r.model}');
        return run(k, r);
      }),
    );
    await catalog.save(
      NamedSource(
        id: 's',
        name: 'Source',
        url: 'https://example.test/v1',
        models: ['first', 'second'],
      ),
      keys: ['a', 'b'],
    );
  });
  tearDown(() async {
    catalog.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
    attempts.clear();
  });
  ChatRequest request() =>
      const ChatRequest(model: 'auto:chain', messages: [], maxOutputTokens: 12);
  Future<LlmProvider> chain({
    RoutingStrategy strategy = RoutingStrategy.manual,
  }) async {
    await catalog.saveChain(
      RoutingChain(
        id: 'chain',
        name: 'Default',
        routes: ['source:s::first', 'source:s::second'],
        strategy: strategy,
      ),
    );
    return catalog.routingProvider('auto:chain');
  }

  test(
    'rotates keys, cools rate limited keys, records usage and persists chain',
    () async {
      run = (key, request) async* {
        expect(request.maxOutputTokens, 12);
        if (key == 'a') throw LlmException('limited', statusCode: 429);
        yield const ChatDelta(text: 'answer');
        yield ChatDelta(usage: UsageStats(inputTokens: 10, outputTokens: 2));
      };
      final provider = await chain();
      final output = await provider.streamChat(request()).toList();
      provider.client.close();
      expect(attempts, ['a/first', 'b/first']);
      expect(
        output.map((d) => d.routingInfo).whereType<String>().single,
        contains('1 fallbacks'),
      );
      expect(catalog.metrics['source:s::first']!.inputTokens, 10);
      final second = catalog.routingProvider('auto:chain');
      await second.streamChat(request()).toList();
      second.client.close();
      expect(attempts.last, 'b/first');
      await catalog.load();
      expect(catalog.chains.single.name, 'Default');
      expect(catalog.metrics['source:s::first']!.successes, 2);
    },
  );
  test('does not fallback after partial text or a tool call', () async {
    run = (key, request) async* {
      yield const ChatDelta(text: 'partial');
      throw LlmException('lost connection');
    };
    final provider = await chain();
    await expectLater(
      provider.streamChat(request()).toList(),
      throwsA(isA<LlmException>()),
    );
    provider.client.close();
    expect(attempts, ['a/first']);
  });
  test(
    'fixed first output deadline ignores keepalives and falls back',
    () async {
      catalog.firstOutputTimeout = const Duration(milliseconds: 30);
      run = (key, request) async* {
        if (request.model == 'first') {
          for (var n = 0; n < 10; n++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            yield const ChatDelta(status: 'waiting');
          }
        } else {
          yield const ChatDelta(text: 'backup');
        }
      };
      final provider = await chain();
      final output = await provider.streamChat(request()).toList();
      provider.client.close();
      expect(output.any((d) => d.text == 'backup'), isTrue);
      expect(attempts, ['a/first', 'b/first', 'a/second']);
    },
  );
  test(
    'closing a request prevents fallback and keeps disabled models out',
    () async {
      run = (key, request) async* {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw LlmException('failed');
      };
      final provider = await chain();
      final future = provider.streamChat(request()).toList();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      provider.client.close();
      expect(await future, isEmpty);
      expect(attempts, ['a/first']);
      catalog.all.single.enabled = false;
      final disabled = catalog.routingProvider('auto:chain');
      await expectLater(
        disabled.streamChat(request()).toList(),
        throwsA(isA<LlmException>()),
      );
      disabled.client.close();
    },
  );
  test(
    'smartest uses explicit owner priority and never assumes provider quota',
    () async {
      run = (key, request) async* {
        yield const ChatDelta(text: 'ok');
      };
      await catalog.saveChain(
        RoutingChain(
          id: 'chain',
          name: 'Smart',
          routes: ['source:s::first', 'source:s::second'],
          strategy: RoutingStrategy.smartest,
          priorities: {'source:s::second': 5},
        ),
      );
      final provider = catalog.routingProvider('auto:chain');
      await provider.streamChat(request()).toList();
      provider.client.close();
      expect(attempts, ['a/second']);
      expect(catalog.metrics['source:s::second']!.inputTokens, 0);
    },
  );
  test('never retries a completed tool call or reasoning chunk', () async {
    for (final delta in [
      ChatDelta(
        toolCalls: [ToolCall(id: 't', name: 'read', arguments: {})],
      ),
      const ChatDelta(reasoning: 'thinking'),
    ]) {
      attempts.clear();
      run = (key, request) async* {
        yield delta;
        throw LlmException('disconnected');
      };
      final provider = await chain();
      await expectLater(
        provider.streamChat(request()).toList(),
        throwsA(isA<LlmException>()),
      );
      provider.client.close();
      expect(attempts.length, 1);
    }
  });
  test(
    'mixed chains fallback across formats but pin native tool history',
    () async {
      await catalog.save(
        NamedSource(
          id: 'native',
          name: 'Native',
          url: 'https://gemini.test',
          kind: ProviderKind.gemini,
          models: ['g'],
        ),
      );
      final mixed = RoutingChain(
        id: 'mixed',
        name: 'Mixed',
        routes: ['source:s::first', 'source:native::g'],
      );
      await catalog.saveChain(mixed);
      expect(catalog.kindForChain(mixed), ProviderKind.custom);
      run = (key, request) async* {
        if (request.model == 'first') throw LlmException('Unavailable');
        yield const ChatDelta(text: 'native answer');
      };
      var provider = catalog.routingProvider(mixed.route);
      var output = await provider
          .streamChat(ChatRequest(model: mixed.route, messages: []))
          .toList();
      provider.client.close();
      expect(
        output.where((d) => d.text.isNotEmpty).single.text,
        'native answer',
      );
      expect(
        output.where((d) => d.providerKind != null).single.providerKind,
        ProviderKind.gemini,
      );
      attempts.clear();
      provider = catalog.routingProvider(mixed.route);
      output = await provider
          .streamChat(
            ChatRequest(
              model: mixed.route,
              messages: [
                Message(
                  role: Role.assistant,
                  provider: ProviderKind.gemini,
                  providerBlocks: [
                    {'thoughtSignature': 'native-only'},
                  ],
                  toolCalls: [ToolCall(id: 't', name: 'read', arguments: {})],
                ),
              ],
            ),
          )
          .toList();
      provider.client.close();
      expect(attempts, ['/g']);
      expect(
        output.where((d) => d.providerKind != null).single.providerKind,
        ProviderKind.gemini,
      );
    },
  );
}

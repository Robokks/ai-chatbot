import 'dart:async';
import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/named_sources.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

class ControlledSource extends LlmProvider {
  ControlledSource(ProviderSettings settings, String key, this.run)
    : super(settings: settings, apiKey: key);
  final Stream<ChatDelta> Function(String, ChatRequest) run;
  @override
  Stream<ChatDelta> streamChat(ChatRequest request) => run(apiKey, request);
  @override
  Future<List<String>> listModels() async => ['a', 'b'];
}

void main() {
  late Directory dir;
  late Storage storage;
  late NamedSources catalog;
  late NamedSource source;
  late DateTime now;
  late Stream<ChatDelta> Function(String, ChatRequest) run;
  final seen = <String>[];
  final caps = <int?>[];
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source_controls');
    storage = await Storage.openAt(dir.path);
    now = DateTime.utc(2026, 11, 4, 12);
    catalog = NamedSources(
      storage,
      clock: () => now,
      factory: (s, key) => ControlledSource(s, key, (k, r) {
        seen.add('$k/${r.model}');
        caps.add(r.maxOutputTokens);
        return run(k, r);
      }),
    );
    source = NamedSource(
      id: 'x',
      name: 'X',
      url: 'https://x.test/v1',
      models: ['a', 'b'],
    );
    run = (key, request) async* {
      yield const ChatDelta(text: 'ok');
      yield ChatDelta(usage: UsageStats(inputTokens: 8, outputTokens: 2));
    };
    await catalog.save(source, keys: ['one', 'two']);
  });
  tearDown(() async {
    catalog.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
    seen.clear();
    caps.clear();
  });
  Future<List<ChatDelta>> send() async {
    final provider = catalog.provider(source, source.route('a'));
    try {
      return await provider
          .streamChat(ChatRequest(model: source.route('a'), messages: []))
          .toList();
    } finally {
      provider.client.close();
    }
  }

  test(
    'source request limit persists and resets at configured UTC window',
    () async {
      source.quota = QuotaPolicy(requests: 1, windowSeconds: 60);
      await catalog.save(source);
      await send();
      await expectLater(send(), throwsA(isA<LlmException>()));
      expect(seen.length, 1);
      await catalog.load();
      source = catalog.all.single;
      await expectLater(send(), throwsA(isA<LlmException>()));
      now = now.add(const Duration(minutes: 1));
      await send();
      expect(catalog.quotaWindow(source).requests, 1);
      expect(seen.length, 2);
    },
  );
  test(
    'key limit rotates to another key and both source and key caps apply',
    () async {
      source.quota = QuotaPolicy(requests: 2);
      source.keyQuotas[0] = QuotaPolicy(requests: 1);
      source.keyQuotas[1] = QuotaPolicy(requests: 1);
      await catalog.save(source);
      await send();
      await send();
      await expectLater(send(), throwsA(isA<LlmException>()));
      expect(seen, ['one/a', 'two/a']);
      expect(catalog.quotaWindow(source).requests, 2);
      expect(catalog.quotaWindow(source, 0).tokens, 10);
      expect(catalog.quotaWindow(source, 1).tokens, 10);
    },
  );
  test(
    'token reservation caps output and settles exact reported usage',
    () async {
      source.quota = QuotaPolicy(tokens: 20000);
      source.keyQuotas[0] = QuotaPolicy(tokens: 10000);
      await catalog.save(source);
      await send();
      expect(caps.single, greaterThan(0));
      expect(caps.single, lessThan(2000));
      expect(catalog.quotaWindow(source).tokens, 10);
      expect(catalog.quotaWindow(source, 0).tokens, 10);
      await catalog.load();
      source = catalog.all.single;
      expect(catalog.quotaWindow(source).tokens, 10);
    },
  );
  test(
    'unknown usage retains reservation until reset and cannot oversubscribe',
    () async {
      source.quota = QuotaPolicy(tokens: 10000, windowSeconds: 60);
      await catalog.save(source);
      final release = Completer<void>();
      run = (key, request) async* {
        await release.future;
        yield const ChatDelta(text: 'unmetered');
      };
      final first = send();
      while (seen.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(send(), throwsA(isA<LlmException>()));
      expect(seen.length, 1);
      release.complete();
      await first;
      expect(catalog.quotaWindow(source).tokens, 10000);
      expect(catalog.quotaWindow(source).unknown, 1);
      await expectLater(send(), throwsA(isA<LlmException>()));
      now = now.add(const Duration(minutes: 1));
      await send();
      expect(seen.length, 2);
    },
  );
  test('disabled model is excluded from direct calls, chain and persisted enabledModels', () async {
    source.modelOptions['a'] = ModelOptions(
      enabled: false,
      vision: true,
      tools: false,
      contextTokens: 128000,
    );
    await catalog.save(source);
    expect(
      () => catalog.provider(source, source.route('a')),
      throwsA(isA<LlmException>()),
    );
    await catalog.saveChain(
      RoutingChain(id: 'c', name: 'C', routes: [source.route('b')]),
    );
    source.modelOptions['b'] = ModelOptions(enabled: false);
    await catalog.save(source);
    final provider = catalog.routingProvider('auto:c');
    await expectLater(
      provider
          .streamChat(const ChatRequest(model: 'auto:c', messages: []))
          .toList(),
      throwsA(isA<LlmException>()),
    );
    provider.client.close();
    await catalog.load();
    expect(catalog.all.single.enabledModels, isEmpty);
    expect(catalog.all.single.modelOptions['a']!.contextTokens, 128000);
    expect(catalog.all.single.modelOptions['a']!.tools, false);
  });
  test(
    'provider presets require Cloudflare account and never guess capabilities',
    () {
      expect(
        SourcePreset.all.where((p) => p.name == 'NVIDIA NIM').single.urlFor(''),
        'https://integrate.api.nvidia.com/v1',
      );
      final cf = SourcePreset.all.where((p) => p.accountRequired).single;
      expect(() => cf.urlFor(''), throwsFormatException);
      expect(() => cf.urlFor('../wrong'), throwsFormatException);
      expect(
        cf.urlFor('account123'),
        'https://api.cloudflare.com/client/v4/accounts/account123/ai/v1',
      );
      expect(ModelOptions().vision, isNull);
      expect(ModelOptions().contextTokens, isNull);
    },
  );
}

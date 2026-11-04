import 'dart:async';
import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/named_sources.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;

class CloseClient extends http.BaseClient {
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();
  @override
  void close() {
    closed = true;
  }
}

class LocalRouteFake extends LlmProvider {
  LocalRouteFake(
    ProviderSettings settings,
    String key,
    this.run,
    CloseClient client,
  ) : super(settings: settings, apiKey: key, client: client);
  final Stream<ChatDelta> Function() run;
  @override
  Stream<ChatDelta> streamChat(ChatRequest request) => run();
  @override
  Future<List<String>> listModels() async => [];
}

void main() {
  late Directory dir;
  late Storage storage;
  late AppState state;
  late NamedSources catalog;
  final seen = <String>[];
  final clients = <CloseClient>[];
  var brokenFactory = false;
  StreamController<ChatDelta>? waiting;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_route');
    storage = await Storage.openAt(dir.path);
    catalog = NamedSources(
      storage,
      factory: (settings, key) {
        if (brokenFactory) throw LlmException('Source no longer available');
        final client = CloseClient();
        clients.add(client);
        return LocalRouteFake(settings, key, () async* {
          seen.add('${settings.baseUrl}/$key');
          if (waiting != null) {
            yield* waiting!.stream;
            return;
          }
          if (settings.baseUrl.contains('failed')) {
            throw LlmException('Unavailable', statusCode: 503);
          }
          yield const ChatDelta(text: 'Actual source answer');
          yield ChatDelta(usage: UsageStats(inputTokens: 9, outputTokens: 3));
        }, client);
      },
    );
    state = AppState(
      storage,
      sources: catalog,
      localModels: LocalModelStore(
        storage,
        dir: Directory('${dir.path}/models')..createSync(),
      ),
      providerFactory: (_, _) =>
          throw StateError('Global provider must not be used'),
    );
    await state.load();
  });
  tearDown(() async {
    state.dispose();
    catalog.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
    seen.clear();
    clients.clear();
    brokenFactory = false;
  });
  test('send dispatches named source with its encrypted key and records actual local usage', () async {
    final source = NamedSource(
      id: 'actual',
      name: 'Actual',
      url: 'https://actual.test/v1',
      models: ['m'],
    );
    await catalog.save(source, keys: ['source-key']);
    await state.selectModel(source.kind, source.route('m'));
    await state.send('Hello', []);
    final reply = state.current!.messages.last;
    expect(reply.text, 'Actual source answer');
    expect(reply.error, isNull);
    expect(seen, ['https://actual.test/v1/source-key']);
    expect(clients.single.closed, isTrue);
    expect(state.isStreaming, isFalse);
    final events = state.host.analytics.summary(const Duration(days: 1)).events;
    expect(events.single.deviceId, 'local');
    expect(events.single.inputTokens, 9);
    expect(events.single.outputTokens, 3);
    expect(events.single.status, 'ok');
    expect(events.single.model, 'custom/${source.route('m')}');
    expect(events.single.durationMs, isNotNull);
    expect(
      storage.getSetting('lab.analytics.v1'),
      isNot(contains('source-key')),
    );
  });
  test('send runs Auto fallback rather than sending the logical id to a global provider', () async {
    await catalog.save(
      NamedSource(
        id: 'bad',
        name: 'Bad',
        url: 'https://failed.test/v1',
        models: ['m'],
      ),
      keys: ['bad-key'],
    );
    await catalog.save(
      NamedSource(
        id: 'ok',
        name: 'Good',
        url: 'https://actual.test/v1',
        models: ['m'],
      ),
      keys: ['good-key'],
    );
    final chain = RoutingChain(
      id: 'default',
      name: 'Default',
      routes: ['source:bad::m', 'source:ok::m'],
    );
    await catalog.saveChain(chain);
    await state.selectModel(catalog.kindForChain(chain), chain.route);
    await state.send('Hello', []);
    final reply = state.current!.messages.last;
    expect(reply.text, 'Actual source answer');
    expect(reply.error, isNull);
    expect(reply.routingInfo, contains('Good'));
    expect(reply.routingInfo, contains('1 fallbacks'));
    expect(seen, [
      'https://failed.test/v1/bad-key',
      'https://actual.test/v1/good-key',
    ]);
    expect(clients.every((c) => c.closed), isTrue);
    expect(state.isStreaming, isFalse);
  });
  test(
    'synchronous source construction errors finish and persist the reply',
    () async {
      final source = NamedSource(
        id: 'actual',
        name: 'Actual',
        url: 'https://actual.test/v1',
        models: ['m'],
      );
      await catalog.save(source, keys: ['source-key']);
      await state.selectModel(source.kind, source.route('m'));
      brokenFactory = true;
      await state.send('Hello', []);
      expect(
        state.current!.messages.last.error,
        contains('Source no longer available'),
      );
      expect(state.isStreaming, isFalse);
      expect(
        storage.loadConversations().single.messages.last.error,
        contains('Source no longer available'),
      );
      expect(
        state.host.analytics
            .summary(const Duration(days: 1))
            .events
            .single
            .status,
        'error',
      );
    },
  );
  test('stop closes the live source client and records cancellation', () async {
    final source = NamedSource(
      id: 'actual',
      name: 'Actual',
      url: 'https://actual.test/v1',
      models: ['m'],
    );
    await catalog.save(source, keys: ['source-key']);
    await state.selectModel(source.kind, source.route('m'));
    waiting = StreamController<ChatDelta>();
    final sent = state.send('Hello', []);
    while (seen.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    state.stop();
    await waiting!.close();
    await sent.timeout(const Duration(seconds: 2));
    expect(clients.single.closed, isTrue);
    expect(state.isStreaming, isFalse);
    expect(
      state.host.analytics
          .summary(const Duration(days: 1))
          .events
          .single
          .status,
      'cancelled',
    );
    waiting = null;
  });
}

import 'dart:convert';
import 'dart:io';
import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/named_sources.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

class NamedFake extends LlmProvider {
  NamedFake(ProviderSettings settings, String key, this.seen) : super(settings: settings, apiKey: key);
  final List<({String url, String key, ChatRequest request})> seen;
  @override Stream<ChatDelta> streamChat(ChatRequest request) async* {
    seen.add((url: baseUrl, key: apiKey, request: request));
    yield ChatDelta(text: 'from $baseUrl');
  }
  @override Future<List<String>> listModels() async => ['auto', 'second'];
}
void main() {
  late Directory dir;
  late Storage storage;
  late NamedSources catalog;
  final seen = <({String url, String key, ChatRequest request})>[];
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sources');
    storage = await Storage.openAt(dir.path);
    catalog = NamedSources(storage, factory: (s, key) => NamedFake(s, key, seen));
  });
  tearDown(() async { catalog.dispose(); await Hive.close(); await dir.delete(recursive: true); seen.clear(); });

  test('same model names on two sources retain distinct routes, URLs, and encrypted keys', () async {
    final one = NamedSource(id: 'one', name: 'FreeLLMAPI', url: 'http://127.0.0.1:9000/v1', models: ['auto']);
    final two = NamedSource(id: 'two', name: 'Second', url: 'https://second.example/v1', models: ['auto']);
    await catalog.save(one, keys: ['first-test-key']);
    await catalog.save(two, keys: ['second-test-key']);
    expect(one.route('auto'), isNot(two.route('auto')));
    expect(storage.getSetting('lab.sources'), isNot(contains('first-test-key')));
    expect(await storage.readSecret('lab.source.one.keys'), contains('first-test-key'));
    await catalog.load();
    for (final source in catalog.all) {
      final provider = catalog.provider(source, source.route('auto'));
      await provider.streamChat(ChatRequest(model: source.route('auto'),
        messages: [Message(role: Role.user, text: 'Hello')], maxOutputTokens: 100)).toList();
      provider.client.close();
    }
    expect(seen.map((r) => r.url).toList(), [one.url, two.url]);
    expect(seen.map((r) => r.key).toList(), ['first-test-key', 'second-test-key']);
    expect(seen.map((r) => r.request.model).toSet(), {'auto'});
    expect(seen.every((r) => r.request.maxOutputTokens == 100), isTrue);
    await catalog.remove(catalog.all.first);
    expect(await storage.readSecret('lab.source.one.keys'), isNull);
    expect(catalog.forRoute(ProviderKind.custom, one.route('auto')), isNull);
  });

  test('health checks load actual models and reject URLs containing credentials', () async {
    final source = NamedSource(id: 'x', name: 'Test', url: 'https://api.example/v1');
    await catalog.save(source);
    await catalog.check(source);
    expect(source.models, ['auto', 'second']);
    expect(catalog.health['x'], startsWith('Healthy'));
    await expectLater(catalog.save(NamedSource(id: 'bad', name: 'Bad', url: 'https://user:password@api.example/v1')), throwsFormatException);
    await expectLater(catalog.save(NamedSource(id: 'bad', name: 'Bad', url: 'https://api.example/v1?key=secret')), throwsFormatException);
  });

  test('Main shares only enabled opted-in sources and routes requests to their exact endpoint', () async {
    final state = AppState(storage, sources: catalog, localModels: LocalModelStore(storage,
      dir: Directory('${dir.path}/models')..createSync()));
    await state.load();
    final source = NamedSource(id: 'one', name: 'First', url: 'https://first.example/v1', models: ['auto'], shared: true);
    final hidden = NamedSource(id: 'two', name: 'Private', url: 'https://private.example/v1', models: ['auto']);
    await catalog.save(source, keys: ['first-test-key']); await catalog.save(hidden);
    final server = state.host.server;
    await server.start(port: 0, address: InternetAddress.loopbackIPv4);
    final device = await server.createKey('Client');
    final http = HttpClient();
    try {
      final request = await http.postUrl(Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions'));
      request.headers.set('authorization', 'Bearer ${device.key}');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'model': 'custom/${source.route('auto')}', 'messages': [{'role': 'user', 'content': 'Hi'}]}));
      final response = await request.close();
      expect(response.statusCode, 200);
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      expect(body['choices'][0]['message']['content'], 'from https://first.example/v1');
      expect(seen.single.key, 'first-test-key');
      expect(state.host.sharedModels().map((m) => m.id), ['custom/${source.route('auto')}']);
      source.enabled = false; await catalog.save(source);
      expect(state.host.sharedModels(), isEmpty);
    } finally { http.close(force: true); await server.stop(); state.dispose(); }
  });
}

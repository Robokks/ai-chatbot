import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/named_sources.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/lab_analytics.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

class _Provider extends LlmProvider {
  _Provider(ProviderSettings s, this.run) : super(settings: s, apiKey: 'test');
  final Stream<ChatDelta> Function(ProviderKind, ChatRequest) run;
  @override
  Stream<ChatDelta> streamChat(ChatRequest request) => run(kind, request);
  @override
  Future<List<String>> listModels() async => ['m'];
}
class _Backend implements HostBackend, HostModelBackend {
  _Backend(this.sources);
  final NamedSources sources;
  @override
  String get deviceName => 'Main';
  @override
  List<SharedModel> sharedModels() => [SharedModel(sources.kindForChain(sources.chains.single), 'auto:mix')];
  @override
  LlmProvider providerFor(ProviderKind kind) => sources.routingProvider('auto:mix');
  @override
  LlmProvider providerForModel(ProviderKind kind, String model) => sources.routingProvider(model);
}
void main() {
  late Directory dir;
  late Storage storage;
  late NamedSources sources;
  late HostServer server;
  late PairedDevice device;
  late HttpClient client;
  final seen = <ProviderKind>[];
  final events = <LabRequestEvent>[];
  var native = false;
  Stream<ChatDelta> run(ProviderKind kind, ChatRequest request) async* {
    seen.add(kind);
    if (request.messages.last.role == Role.tool) {
      expect(request.messages[1].provider, native ? ProviderKind.gemini : ProviderKind.groq);
      if (native) {
        expect(request.messages[1].providerBlocks!.single['thoughtSignature'], 'signed');
        throw LlmException('Native continuation failed', statusCode: 503);
      }
      yield const ChatDelta(text: 'Finished');
    } else {
      if (kind == ProviderKind.gemini && !native) throw LlmException('Unavailable', statusCode: 503);
      yield ChatDelta(toolCalls: [ToolCall(id: 'one', name: 'inspect', arguments: {})],
        providerBlocks: native ? [{'thoughtSignature': 'signed'}] : null);
    }
    yield ChatDelta(usage: UsageStats(inputTokens: 8, outputTokens: 3));
  }
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mixed-route');
    storage = await Storage.openAt(dir.path);
    sources = NamedSources(storage, factory: (s, key) => _Provider(s, run));
    await sources.save(NamedSource(id: 'g', name: 'Gemini', kind: ProviderKind.gemini, url: 'https://gemini.test', models: ['m']), keys: ['g']);
    await sources.save(NamedSource(id: 'r', name: 'Groq', kind: ProviderKind.groq, url: 'https://groq.test', models: ['m']), keys: ['r']);
    await sources.saveChain(RoutingChain(id: 'mix', name: 'Mixed', routes: ['source:g::m', 'source:r::m']));
    server = HostServer(_Backend(sources), loadDevices: () async => [], saveDevices: (_) async {},
      onAnalytics: (event) async { events.add(event); });
    await server.start(port: 0, address: InternetAddress.loopbackIPv4);
    device = await server.createKey('PC');
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.stop();
    sources.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
    seen.clear(); events.clear(); native = false;
  });
  Future<(int, Map<String, dynamic>)> call(List<Map<String, dynamic>> messages) async {
    final request = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}/v1/messages'));
    request.headers.set('x-api-key', device.key);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'model': server.backend.sharedModels().single.id, 'max_tokens': 32,
      'tools': [{'name': 'inspect', 'input_schema': {'type': 'object'}}], 'messages': messages}));
    final response = await request.close();
    return (response.statusCode, Map<String, dynamic>.from(jsonDecode(await utf8.decoder.bind(response).join()) as Map));
  }
  Future<(int, Map<String, dynamic>)> roundTrip() async {
    final messages = <Map<String, dynamic>>[{'role': 'user', 'content': 'Inspect'}];
    final first = await call(messages);
    expect(first.$1, 200);
    expect(first.$2['stop_reason'], 'tool_use');
    messages.add({'role': 'assistant', 'content': first.$2['content']});
    messages.add({'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'one', 'content': 'ok'}]});
    return call(messages);
  }
  test('mixed native providers fall back before output and pin subsequent tool history', () async {
    final second = await roundTrip();
    expect(second.$1, 200);
    expect(seen, [ProviderKind.gemini, ProviderKind.groq, ProviderKind.groq]);
    expect(events, hasLength(2));
    expect(events.every((e) => e.inputTokens == 8 && e.outputTokens == 3), isTrue);
  });
  test('native signatures survive replay and continuation cannot switch API formats', () async {
    native = true;
    final second = await roundTrip();
    expect(second.$1, 502);
    expect(seen, [ProviderKind.gemini, ProviderKind.gemini]);
    expect(events.last.status, 'error');
  });
}

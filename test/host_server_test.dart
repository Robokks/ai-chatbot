import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class EchoProvider extends LlmProvider {
  EchoProvider(ProviderKind kind) : super(settings: ProviderSettings(kind: kind), apiKey: '');
  ChatRequest? last;

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    last = request;
    yield const ChatDelta(reasoning: 'hmm');
    yield ChatDelta(text: 'Echo: ${request.messages.last.text}');
    yield ChatDelta(usage: UsageStats(inputTokens: 7, outputTokens: 3));
  }

  @override
  Future<List<String>> listModels() async => [];
}

class FakeBackend implements HostBackend {
  final providers = <ProviderKind, EchoProvider>{};
  @override
  String get deviceName => 'Old phone';
  @override
  List<SharedModel> sharedModels() => const [
        SharedModel(ProviderKind.local, 'LFM2-1.2B-Q4_K_M', displayName: 'LFM2 1.2B'),
        SharedModel(ProviderKind.anthropic, 'claude-sonnet-5-5'),
      ];
  @override
  LlmProvider providerFor(ProviderKind kind) => providers.putIfAbsent(kind, () => EchoProvider(kind));
}

void main() {
  late HostServer host;
  late FakeBackend backend;
  late List<PairedDevice> saved;
  late String base;
  final client = HttpClient();

  Future<(int, Object?)> call(String method, String path, {Object? body, String? key}) async {
    final req = await client.openUrl(method, Uri.parse('$base$path'));
    if (key != null) req.headers.set('authorization', 'Bearer $key');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      json = text;
    }
    return (res.statusCode, json);
  }

  Future<String> pair() async {
    final (status, body) = await call('POST', '/pair', body: {'pin': host.pin, 'device': 'Laptop'});
    expect(status, 200);
    return (body as Map)['key'] as String;
  }

  setUp(() async {
    backend = FakeBackend();
    saved = [];
    host = HostServer(backend, loadDevices: () async => [], saveDevices: (d) async => saved = List.of(d));
    await host.start(port: 0, address: InternetAddress.loopbackIPv4);
    base = 'http://127.0.0.1:${host.port}';
  });

  tearDown(() => host.stop());

  test('health is public and names the host', () async {
    final (status, body) = await call('GET', '/health');
    expect(status, 200);
    expect((body as Map)['name'], 'Old phone');
  });

  test('API needs an access key', () async {
    expect((await call('GET', '/v1/models')).$1, 401);
    expect((await call('GET', '/v1/models', key: 'cbh_wrong')).$1, 401);
  });

  test('pairing with the PIN returns a working key, then the PIN rotates', () async {
    final pinBefore = host.pin;
    final key = await pair();
    expect(host.pin, isNot(pinBefore));
    expect(saved.single.name, 'Laptop');
    final (status, body) = await call('GET', '/v1/models', key: key);
    expect(status, 200);
    final ids = [for (final m in (body as Map)['data'] as List) m['id']];
    expect(ids, ['local/LFM2-1.2B-Q4_K_M', 'anthropic/claude-sonnet-5-5']);
  });

  test('wrong PINs are limited', () async {
    for (var i = 0; i < HostServer.maxPinAttempts; i++) {
      expect((await call('POST', '/pair', body: {'pin': 'xxxxxx'})).$1, 401);
    }
    // Locked: even the right PIN is refused for a minute.
    expect((await call('POST', '/pair', body: {'pin': host.pin})).$1, 429);
  });

  test('non-streaming chat completion', () async {
    final key = await pair();
    final (status, body) = await call('POST', '/v1/chat/completions', key: key, body: {
      'model': 'local/LFM2-1.2B-Q4_K_M',
      'messages': [
        {'role': 'system', 'content': 'Be brief'},
        {'role': 'user', 'content': 'hello'},
      ],
    });
    expect(status, 200);
    final msg = ((body as Map)['choices'] as List).first['message'];
    expect(msg['content'], 'Echo: hello');
    expect(body['usage']['completion_tokens'], 3);
    final sent = backend.providers[ProviderKind.local]!.last!;
    expect(sent.model, 'LFM2-1.2B-Q4_K_M');
    expect(sent.systemPrompt, 'Be brief');
    expect(host.log.first.device, 'Laptop');
  });

  test('streaming chat completion in OpenAI format with usage', () async {
    final key = await pair();
    final (status, body) = await call('POST', '/v1/chat/completions', key: key, body: {
      'model': 'anthropic/claude-sonnet-5-5',
      'stream': true,
      'stream_options': {'include_usage': true},
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,AQID'}},
          ],
        },
      ],
    });
    expect(status, 200);
    final events = (body as String)
        .split('\n\n')
        .where((l) => l.startsWith('data: '))
        .map((l) => l.substring(6))
        .toList();
    expect(events.last, '[DONE]');
    final chunks = events.where((e) => e != '[DONE]').map((e) => jsonDecode(e) as Map).toList();
    final content = chunks
        .expand((c) => c['choices'] as List)
        .map((c) => c['delta']['content'] ?? '')
        .join();
    expect(content, 'Echo: look');
    expect(chunks.any((c) => (c['choices'] as List).firstOrNull?['delta']['reasoning_content'] == 'hmm'),
        isTrue);
    expect(chunks.last['usage']['prompt_tokens'], 7);
    final sent = backend.providers[ProviderKind.anthropic]!.last!;
    expect(sent.messages.single.attachments.single.bytes, [1, 2, 3]);
  });

  test('unshared models and revoked keys are refused', () async {
    final key = await pair();
    final (status, _) = await call('POST', '/v1/chat/completions', key: key, body: {
      'model': 'openai/gpt-5',
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
    });
    expect(status, 404);
    await host.revoke(host.devices.single);
    expect((await call('GET', '/v1/models', key: key)).$1, 401);
  });

  test('access keys for other apps', () async {
    final d = await host.createKey('Open WebUI');
    expect(d.key, startsWith('cbh_'));
    expect((await call('GET', '/v1/models', key: d.key)).$1, 200);
  });

  test('bridge rejects bad requests clearly', () {
    expect(() => parseChatRequest({'messages': []}), throwsA(isA<BridgeException>()));
    expect(
        () => parseChatRequest({
              'model': 'x',
              'messages': [
                {'role': 'system', 'content': 'only system'},
              ],
            }),
        throwsA(isA<BridgeException>()));
    expect(SharedModel.parseId('anthropic/claude-x'), (ProviderKind.anthropic, 'claude-x'));
    expect(SharedModel.parseId('nonsense'), isNull);
  });
}

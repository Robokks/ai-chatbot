import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';

class EchoProvider extends LlmProvider {
  EchoProvider(ProviderKind kind) : super(settings: ProviderSettings(kind: kind), apiKey: '');

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    yield const ChatDelta(text: 'You said: ');
    yield ChatDelta(text: request.messages.last.text);
    if (request.systemPrompt != null) yield ChatDelta(text: ' [${request.systemPrompt}]');
  }

  @override
  Future<List<String>> listModels() async => [];
}

class Backend implements HostBackend {
  @override
  String get deviceName => 'Old phone';
  @override
  List<SharedModel> sharedModels() => const [
        SharedModel(ProviderKind.anthropic, 'claude-sonnet-5-5'),
        SharedModel(ProviderKind.local, 'LFM2-1.2B-Q4_K_M', displayName: 'LFM2 1.2B'),
      ];
  @override
  LlmProvider providerFor(ProviderKind kind) => EchoProvider(kind);
}

void main() {
  late HostServer host;
  late String base;
  late String key;
  final http = HttpClient();

  Future<(int, String, ContentType?)> call(String method, String path,
      {Object? body, bool auth = true}) async {
    final req = await http.openUrl(method, Uri.parse('$base$path'));
    if (auth) req.headers.set('authorization', 'Bearer $key');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join(), res.headers.contentType);
  }

  setUp(() async {
    host = HostServer(Backend(), loadDevices: () async => [], saveDevices: (_) async {});
    await host.start(port: 0, address: InternetAddress.loopbackIPv4);
    base = 'http://127.0.0.1:${host.port}';
    key = (await host.createKey('Tester')).key;
  });

  tearDown(() => host.stop());

  group('UTCP', () {
    test('manual needs a key and describes HTTP tools on this host', () async {
      expect((await call('GET', '/utcp', auth: false)).$1, 401);
      final (status, body, _) = await call('GET', '/utcp');
      expect(status, 200);
      final manual = jsonDecode(body) as Map;
      expect(manual['utcp_version'], isNotEmpty);
      final tools = {for (final t in manual['tools'] as List) t['name']: t};
      expect(tools.keys, containsAll(['list_models', 'chat']));
      final tpl = tools['chat']['tool_call_template'] as Map;
      expect(tpl['call_template_type'], 'http');
      expect(tpl['url'], '$base/tools/chat');
      expect(tpl['body_field'], 'request');
      expect(tpl['auth']['api_key'], r'Bearer ${CHATBOT_HOST_KEY}');
      expect(tools['chat']['inputs']['properties']['request']['properties']['model']['enum'],
          ['anthropic/claude-sonnet-5-5', 'local/LFM2-1.2B-Q4_K_M']);
    });

    test('chat tool endpoint answers, defaulting to the on-device model', () async {
      final (status, body, _) = await call('POST', '/tools/chat', body: {'prompt': 'ping', 'system': 'S'});
      expect(status, 200);
      final j = jsonDecode(body) as Map;
      expect(j['text'], 'You said: ping [S]');
      expect(j['model'], 'local/LFM2-1.2B-Q4_K_M');
      expect((await call('POST', '/tools/chat', body: {'prompt': 'x', 'model': 'openai/gpt-5'})).$1, 404);
    });
  });

  group('A2A', () {
    test('agent card is public and points at the JSON-RPC endpoint', () async {
      final (status, body, _) = await call('GET', '/.well-known/agent-card.json', auth: false);
      expect(status, 200);
      final card = jsonDecode(body) as Map;
      expect(card['name'], 'Chatbot on Old phone');
      expect((card['supportedInterfaces'] as List).single,
          {'url': '$base/a2a', 'protocolBinding': 'JSONRPC', 'protocolVersion': '1.0'});
      expect((card['skills'] as List).map((s) => s['id']), contains('local/LFM2-1.2B-Q4_K_M'));
      expect(card['securitySchemes']['bearer'], isNotNull);
    });

    test('SendMessage returns an agent message', () async {
      final (status, body, _) = await call('POST', '/a2a', body: {
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'SendMessage',
        'params': {
          'message': {
            'role': 'ROLE_USER',
            'messageId': 'm1',
            'contextId': 'ctx1',
            'parts': [
              {'text': 'hello agent'},
            ],
          },
          'metadata': {'model': 'anthropic/claude-sonnet-5-5'},
        },
      });
      expect(status, 200);
      final j = jsonDecode(body) as Map;
      expect(j['id'], 7);
      final msg = j['result']['message'] as Map;
      expect(msg['role'], 'ROLE_AGENT');
      expect(msg['contextId'], 'ctx1');
      expect(msg['parts'][0]['text'], 'You said: hello agent');
    });

    test('SendStreamingMessage streams task, artifact chunks and completion', () async {
      final (status, body, type) = await call('POST', '/a2a', body: {
        'jsonrpc': '2.0',
        'id': 'r1',
        'method': 'SendStreamingMessage',
        'params': {
          'message': {
            'role': 'ROLE_USER',
            'messageId': 'm2',
            'parts': [
              {'text': 'stream it'},
            ],
          },
        },
      });
      expect(status, 200);
      expect(type?.mimeType, 'text/event-stream');
      final events = body
          .split('\n\n')
          .where((e) => e.startsWith('data: '))
          .map((e) => (jsonDecode(e.substring(6)) as Map)['result'] as Map)
          .toList();
      expect(events.first['task']['status']['state'], 'TASK_STATE_WORKING');
      final text = events
          .where((e) => e.containsKey('artifactUpdate'))
          .map((e) => e['artifactUpdate']['artifact']['parts'][0]['text'])
          .join();
      expect(text, 'You said: stream it');
      expect(events.last['statusUpdate']['status']['state'], 'TASK_STATE_COMPLETED');
    });

    test('errors use JSON-RPC codes; no key means 401', () async {
      final unknown = jsonDecode((await call('POST', '/a2a', body: {
        'jsonrpc': '2.0', 'id': 1, 'method': 'Nope', 'params': {},
      })).$2) as Map;
      expect(unknown['error']['code'], -32601);
      final bad = jsonDecode((await call('POST', '/a2a', body: {
        'jsonrpc': '2.0', 'id': 2, 'method': 'SendMessage', 'params': {'message': {}},
      })).$2) as Map;
      expect(bad['error']['code'], -32602);
      expect((await call('POST', '/a2a', body: {}, auth: false)).$1, 401);
    });
  });

  group('MCP', () {
    Future<McpClient> connect(String token) async {
      final client = McpClient(const Implementation(name: 'test', version: '1.0.0'));
      final transport = StreamableHttpClientTransport(
        Uri.parse('http://127.0.0.1:${host.mcpPort}/mcp'),
        opts: StreamableHttpClientTransportOptions(requestInit: {
          'headers': {'Authorization': 'Bearer $token'},
        }),
      );
      await client.connect(transport);
      return client;
    }

    test('lists and calls tools with a valid key', () async {
      expect(host.mcpPort, isNotNull);
      final client = await connect(key);
      final tools = (await client.listTools()).tools.map((t) => t.name);
      expect(tools, containsAll(['list_models', 'chat']));
      final result = await client.callTool(
          const CallToolRequest(name: 'chat', arguments: {'prompt': 'via mcp'}));
      expect((result.content.single as TextContent).text, 'You said: via mcp');
      final models = await client.callTool(const CallToolRequest(name: 'list_models'));
      expect((models.content.single as TextContent).text, contains('LFM2 1.2B'));
      await client.close();
    });

    test('rejects a missing or wrong key', () async {
      await expectLater(connect('cbh_wrong'), throwsA(anything));
    });
  });
}

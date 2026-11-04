import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _Provider extends LlmProvider {
  _Provider()
    : super(
        settings: ProviderSettings(kind: ProviderKind.openai),
        apiKey: '',
      );
  ChatRequest? request;
  bool replayMode = false;
  @override
  Future<List<String>> listModels() async => ['test'];
  @override
  Stream<ChatDelta> streamChat(ChatRequest input) async* {
    request = input;
    yield const ChatDelta(text: 'Done');
    if (replayMode) {
      yield ChatDelta(
        toolCalls: [
          for (final id in ['a', 'b'])
            ToolCall(id: id, name: 'read', arguments: {'path': id}),
        ],
        providerBlocks: [
          {'text': 'Done'},
          for (final id in ['a', 'b'])
            {
              'functionCall': {
                'name': 'read',
                'args': {'path': id},
              },
              'thoughtSignature': 'signed-$id',
            },
        ],
      );
    } else if (input.tools.isNotEmpty) {
      yield ChatDelta(
        toolCalls: [
          ToolCall(
            id: 'patch1',
            name: 'apply_patch',
            arguments: {'input': '*** Begin Patch\n*** End Patch'},
          ),
        ],
      );
    }
    yield ChatDelta(usage: UsageStats(inputTokens: 3, outputTokens: 5));
  }
}

class _Backend implements HostBackend {
  final provider = _Provider();
  @override
  String get deviceName => 'Main';
  @override
  List<SharedModel> sharedModels() => const [
    SharedModel(ProviderKind.openai, 'test'),
    SharedModel(ProviderKind.gemini, 'test'),
  ];
  @override
  LlmProvider providerFor(ProviderKind kind) => provider;
}

void main() {
  late HostServer host;
  late _Backend backend;
  late PairedDevice device;
  late HttpClient client;
  Future<(int, String)> post(
    Map<String, dynamic> body, {
    String key = 'key',
  }) async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${host.port}/v1/responses'),
    );
    request.headers.set('authorization', 'Bearer $key');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  }

  setUp(() async {
    backend = _Backend();
    client = HttpClient();
    device = PairedDevice(id: 'pc', name: 'Client', key: 'key');
    host = HostServer(
      backend,
      loadDevices: () async => [device],
      saveDevices: (_) async {},
    );
    await host.start(address: InternetAddress.loopbackIPv4, port: 0);
  });
  tearDown(() async {
    client.close(force: true);
    await host.stop();
  });
  test(
    'authenticated Responses SSE completes raw custom patch tools',
    () async {
      final (status, text) = await post({
        'model': 'openai/test',
        'input': 'Fix',
        'store': false,
        'stream': true,
        'tools': [
          {'type': 'custom', 'name': 'apply_patch'},
        ],
      });
      expect(status, 200);
      final events = text
          .split('\n')
          .where((line) => line.startsWith('data: '))
          .map((line) => jsonDecode(line.substring(6)) as Map)
          .toList();
      expect(
        events.any(
          (e) =>
              e['type'] == 'response.output_text.delta' && e['delta'] == 'Done',
        ),
        isTrue,
      );
      final done =
          events
                  .where((e) => e['type'] == 'response.output_item.done')
                  .last['item']
              as Map;
      expect(done['type'], 'custom_tool_call');
      expect(done['input'], '*** Begin Patch\n*** End Patch');
      expect(events.last['type'], 'response.completed');
      expect(device.usage.tokens, 8);
    },
  );
  test(
    'Responses enforces authentication, allowed models and tool policy',
    () async {
      final base = {'model': 'openai/test', 'input': 'Hi'};
      expect((await post(base, key: 'wrong')).$1, 401);
      await host.updateAccess(device, ClientAccess(models: {'openai/other'}));
      expect((await post(base)).$1, 403);
      await host.updateAccess(device, ClientAccess(tools: {}));
      expect(
        (await post({
          ...base,
          'tools': [
            {
              'type': 'function',
              'name': 'bad',
              'parameters': {'type': 'object'},
            },
          ],
        })).$1,
        403,
      );
      expect(backend.provider.request, isNull);
    },
  );
  test(
    'Gemini parallel Responses calls restore exact native replay signatures',
    () async {
      backend.provider.replayMode = true;
      final tools = [
        {
          'type': 'function',
          'name': 'read',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
          },
        },
      ];
      final (firstStatus, firstBody) = await post({
        'model': 'gemini/test',
        'input': 'Fix',
        'tools': tools,
      });
      expect(firstStatus, 200);
      final output = (jsonDecode(firstBody) as Map)['output'] as List;
      expect(output.length, 3);
      final (secondStatus, secondBody) = await post({
        'model': 'gemini/test',
        'tools': tools,
        'input': [
          {'role': 'user', 'content': 'Fix'},
          ...output,
          {'type': 'function_call_output', 'call_id': 'a', 'output': 'A'},
          {'type': 'function_call_output', 'call_id': 'b', 'output': 'B'},
        ],
      });
      expect(secondStatus, 200, reason: secondBody);
      final assistant = backend.provider.request!.messages[1];
      expect(assistant.text, 'Done');
      expect(assistant.toolCalls.length, 2);
      expect(assistant.provider, ProviderKind.gemini);
      expect(assistant.providerBlocks!.last['thoughtSignature'], 'signed-b');
    },
  );

  test('Responses caps output tokens and persists request quota', () async {
    await host.updateAccess(
      device,
      ClientAccess(tokensPerDay: 20000, requestsPerDay: 1),
    );
    final base = {
      'model': 'openai/test',
      'input': 'Hi',
      'max_output_tokens': 100,
    };
    expect((await post(base)).$1, 200);
    expect(backend.provider.request!.maxOutputTokens, 100);
    expect(device.usage.tokens, 8);
    expect((await post(base)).$1, 429);
  });
}

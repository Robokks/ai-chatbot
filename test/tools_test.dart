import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/anthropic_provider.dart';
import 'package:ai_chatbot/data/llm/gemini_provider.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/openai_provider.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:ai_chatbot/tools/cli_runner.dart';
import 'package:ai_chatbot/tools/tool_registry.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:ai_chatbot/tools/utcp_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A provider that asks for a tool on its first turn, then answers.
class ScriptedProvider extends LlmProvider {
  ScriptedProvider(ProviderSettings s) : super(settings: s, apiKey: 'k');
  final requests = <ChatRequest>[];

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    requests.add(request);
    final last = request.messages.last;
    if (last.role == Role.tool) {
      yield ChatDelta(text: 'Tool said: ${last.toolResults.single.text}');
    } else {
      yield const ChatDelta(text: 'Let me check. ');
      yield ChatDelta(toolCalls: [
        ToolCall(id: 'c1', name: request.tools.first.name, arguments: {'text': 'hi'}),
      ]);
    }
  }

  @override
  Future<List<String>> listModels() async => [];
}

class EchoSource extends ToolSource {
  EchoSource(super.config, super.secret);
  @override
  Future<List<SourceTool>> discover() async => const [
        SourceTool(name: 'echo', description: 'Echo text', inputSchema: {'type': 'object'}),
      ];
  @override
  Future<ToolOutput> call(String tool, Map<String, dynamic> a) async => ToolOutput('ECHO ${a['text']}');
}

class EchoProvider extends LlmProvider {
  EchoProvider(ProviderKind kind) : super(settings: ProviderSettings(kind: kind), apiKey: '');
  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    yield ChatDelta(text: 'host got: ${request.messages.last.text}');
  }

  @override
  Future<List<String>> listModels() async => [];
}

class HostBackendFake implements HostBackend {
  @override
  String get deviceName => 'Old phone';
  @override
  List<SharedModel> sharedModels() => const [SharedModel(ProviderKind.local, 'LFM2-1.2B-Q4_K_M')];
  @override
  LlmProvider providerFor(ProviderKind kind) => EchoProvider(kind);
}

http.StreamedResponse _sse(String body) => http.StreamedResponse(Stream.value(utf8.encode(body)), 200);

void main() {
  group('agent loop', () {
    late Directory dir;
    late AppState state;
    late ScriptedProvider llm;

    Future<void> setup({bool ask = false}) async {
      dir = await Directory.systemTemp.createTemp('agent');
      final storage = await Storage.openAt(dir.path);
      final registry = ToolRegistry(storage, sourceFactory: (c, s) => EchoSource(c, s));
      state = AppState(storage,
          localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()),
          tools: registry,
          providerFactory: (s, k) => llm = ScriptedProvider(s));
      await state.load();
      await state.setKey(ProviderKind.anthropic, 'sk');
      await registry.addOrUpdate(ToolSourceConfig(
          id: 's1', type: ToolSourceType.mcp, name: 'Demo', url: 'x', askBeforeRun: ask));
    }

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('runs the tool and continues with its result', () async {
      await setup();
      await state.send('use the tool', []);
      final msgs = state.current!.messages;
      expect(msgs.map((m) => m.role), [Role.user, Role.assistant, Role.tool, Role.assistant]);
      expect(msgs[1].toolCalls.single.name, 'demo_echo');
      expect(msgs[2].toolResults.single.text, 'ECHO hi');
      expect(msgs[3].text, 'Tool said: ECHO hi');
      expect(llm.requests.first.tools.single.sourceLabel, 'MCP server · Demo');
      // Saved and reloaded with the tool turn intact.
      final saved = state.storage.loadConversations().single.messages;
      expect(saved[1].toolCalls.single.arguments, {'text': 'hi'});
      expect(saved[2].toolResults.single.callId, 'c1');
    });

    test('asks for approval and reports a denial to the AI', () async {
      await setup(ask: true);
      final sending = state.send('use the tool', []);
      while (state.pendingApproval == null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(state.pendingApproval!.preview, contains('"text": "hi"'));
      state.answerApproval(false);
      await sending;
      final msgs = state.current!.messages;
      expect(msgs[2].toolResults.single.isError, isTrue);
      expect(msgs.last.text, contains('declined'));
    });

    test('regenerate drops the whole tool exchange', () async {
      await setup();
      await state.send('use the tool', []);
      await state.regenerate();
      expect(state.current!.messages.where((m) => m.role == Role.user), hasLength(1));
      expect(state.current!.messages.last.text, 'Tool said: ECHO hi');
    });
  });

  group('providers', () {
    final tool = const ToolSpec(
      name: 'demo_echo',
      description: 'Echo',
      inputSchema: {'type': 'object', 'properties': {'text': {'type': 'string'}}},
      sourceId: 's',
      sourceLabel: 'Demo',
    );
    List<Message> toolHistory(ProviderKind p, {List<Map<String, dynamic>>? blocks}) => [
          Message(role: Role.user, text: 'go'),
          Message(
            role: Role.assistant,
            provider: p,
            text: 'Checking',
            toolCalls: [ToolCall(id: 'c1', name: 'demo_echo', arguments: {'text': 'hi'})],
            providerBlocks: blocks,
          ),
          Message(role: Role.tool, toolResults: [ToolResult(callId: 'c1', name: 'demo_echo', text: 'ECHO hi')]),
        ];

    test('Claude: tools, signed thinking replayed, tool_result as user content', () {
      final p = AnthropicProvider(settings: ProviderSettings(kind: ProviderKind.anthropic), apiKey: 'k');
      final blocks = [
        {'type': 'thinking', 'thinking': 'plan', 'signature': 'sig'},
        {'type': 'text', 'text': ''},
        {'type': 'tool_use', 'id': 'c1', 'name': 'demo_echo', 'input': {'text': 'hi'}},
      ];
      final body = p.buildBody(ChatRequest(
          model: 'claude-opus-5-5', messages: toolHistory(ProviderKind.anthropic, blocks: blocks), tools: [tool]));
      expect(body['tools'][0]['input_schema']['properties'], contains('text'));
      final msgs = body['messages'] as List;
      expect((msgs[1]['content'] as List).map((b) => b['type']), ['thinking', 'tool_use']);
      expect(msgs[2]['content'][0], {'type': 'tool_result', 'tool_use_id': 'c1', 'content': 'ECHO hi'});
    });

    test('Claude stream: tool_use with streamed JSON and thinking signature', () async {
      final events = [
        {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': ''}},
        {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'thinking_delta', 'thinking': 'plan'}},
        {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'SIG'}},
        {'type': 'content_block_stop', 'index': 0},
        {'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'tool_use', 'id': 'tu1', 'name': 'demo_echo', 'input': {}}},
        {'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'input_json_delta', 'partial_json': '{"te'}},
        {'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'input_json_delta', 'partial_json': 'xt":"hi"}'}},
        {'type': 'content_block_stop', 'index': 1},
      ].map((e) => 'data: ${jsonEncode(e)}\n\n').join();
      final p = AnthropicProvider(
          settings: ProviderSettings(kind: ProviderKind.anthropic),
          apiKey: 'k',
          client: MockClient.streaming((_, _) async => _sse(events)));
      final deltas = await p.streamChat(ChatRequest(model: 'claude-opus-5-5', messages: [Message(role: Role.user, text: 'go')], tools: [tool])).toList();
      final call = deltas.expand((d) => d.toolCalls).single;
      expect(call.id, 'tu1');
      expect(call.arguments, {'text': 'hi'});
      final blocks = deltas.lastWhere((d) => d.providerBlocks != null).providerBlocks!;
      expect(blocks[0], {'type': 'thinking', 'thinking': 'plan', 'signature': 'SIG'});
      expect(blocks[1]['input'], {'text': 'hi'});
    });

    test('OpenAI-compatible: tool_calls stream and tool messages', () async {
      final p = OpenAiProvider(
          settings: ProviderSettings(kind: ProviderKind.openai),
          apiKey: 'k',
          client: MockClient.streaming((_, _) async => _sse(
              'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"demo_echo","arguments":"{\\"te"}}]}}]}\n\n'
              'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"xt\\":\\"hi\\"}"}}]},"finish_reason":"tool_calls"}]}\n\n'
              'data: [DONE]\n\n')));
      final deltas = await p.streamChat(ChatRequest(model: 'gpt-5', messages: [Message(role: Role.user, text: 'go')], tools: [tool])).toList();
      final call = deltas.expand((d) => d.toolCalls).single;
      expect(call.id, 'call_9');
      expect(call.name, 'demo_echo');
      expect(call.arguments, {'text': 'hi'});

      final body = p.buildBody(ChatRequest(model: 'gpt-5', messages: toolHistory(ProviderKind.openai), tools: [tool]));
      final msgs = body['messages'] as List;
      expect(body['tools'][0]['function']['name'], 'demo_echo');
      expect(msgs[1]['tool_calls'][0]['function']['arguments'], '{"text":"hi"}');
      expect(msgs[2], {'role': 'tool', 'tool_call_id': 'c1', 'content': 'ECHO hi'});
    });

    test('Gemini: functionCall parsed and functionResponse sent', () async {
      final p = GeminiProvider(
          settings: ProviderSettings(kind: ProviderKind.gemini),
          apiKey: 'k',
          client: MockClient.streaming((_, _) async => _sse(
              'data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"demo_echo","args":{"text":"hi"}},"thoughtSignature":"TS"}]}}]}\n\n')));
      final deltas = await p.streamChat(ChatRequest(model: 'gemini-2.5-pro', messages: [Message(role: Role.user, text: 'go')], tools: [tool])).toList();
      final d = deltas.lastWhere((d) => d.toolCalls.isNotEmpty);
      expect(d.toolCalls.single.arguments, {'text': 'hi'});
      expect(d.providerBlocks!.single['thoughtSignature'], 'TS');

      final body = p.buildBody(ChatRequest(model: 'gemini-2.5-pro', messages: toolHistory(ProviderKind.gemini), tools: [tool]));
      expect(body['tools'][0]['functionDeclarations'][0]['parametersJsonSchema'], isNotNull);
      expect((body['contents'] as List)[2]['parts'][0]['functionResponse'],
          {'name': 'demo_echo', 'response': {'result': 'ECHO hi'}});
    });

    test('home server bridge forwards tools and returns tool_calls', () {
      final req = parseChatRequest({
        'model': 'anthropic/claude-opus-5-5',
        'tools': [
          {'type': 'function', 'function': {'name': 'demo_echo', 'description': 'Echo', 'parameters': {'type': 'object'}}},
        ],
        'messages': [
          {'role': 'user', 'content': 'go'},
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {'id': 'c1', 'type': 'function', 'function': {'name': 'demo_echo', 'arguments': '{"text":"hi"}'}},
            ],
            'x_provider': 'anthropic',
            'x_provider_blocks': [
              {'type': 'tool_use', 'id': 'c1', 'name': 'demo_echo', 'input': {'text': 'hi'}},
            ],
          },
          {'role': 'tool', 'tool_call_id': 'c1', 'content': 'ECHO hi'},
        ],
      });
      expect(req.tools.single.name, 'demo_echo');
      expect(req.messages[1].provider, ProviderKind.anthropic);
      expect(req.messages[1].providerBlocks, isNotNull);
      expect(req.messages[2].toolResults.single.name, 'demo_echo');

      final w = CompletionWriter('anthropic/claude-opus-5-5');
      final chunk = w.add(ChatDelta(toolCalls: [ToolCall(id: 'x', name: 'demo_echo', arguments: {'a': 1})]))!;
      expect(chunk['choices'][0]['delta']['tool_calls'][0]['function']['arguments'], '{"a":1}');
      expect(w.finalChunk()['choices'][0]['finish_reason'], 'tool_calls');
    });
  });

  group('tool sources against a real host', () {
    late HostServer host;
    late String key;
    late Directory dir;
    late ToolRegistry registry;

    setUp(() async {
      host = HostServer(HostBackendFake(), loadDevices: () async => [], saveDevices: (_) async {});
      await host.start(port: 0, address: InternetAddress.loopbackIPv4);
      key = (await host.createKey('Laptop')).key;
      dir = await Directory.systemTemp.createTemp('reg');
      registry = ToolRegistry(await Storage.openAt(dir.path));
      await registry.load();
    });

    tearDown(() async {
      registry.dispose();
      await host.stop();
      await Hive.close();
      await dir.delete(recursive: true);
    });

    Future<String> callFirst(ToolSourceConfig c, Map<String, dynamic> args) async {
      await registry.addOrUpdate(c, secret: key);
      expect(registry.status[c.id]!.error, isNull);
      final toolName = args.remove('_tool') as String;
      final spec = registry.activeTools().firstWhere((t) => t.name.endsWith(toolName));
      final r = await registry.execute(ToolCall(id: '1', name: spec.name, arguments: args));
      expect(r.isError, isFalse, reason: r.text);
      return r.text;
    }

    test('MCP', () async {
      final text = await callFirst(
          ToolSourceConfig(id: 'm', type: ToolSourceType.mcp, name: 'Phone', url: 'http://127.0.0.1:${host.mcpPort}/mcp'),
          {'_tool': 'chat', 'prompt': 'via mcp'});
      expect(text, 'host got: via mcp');
    });

    test('UTCP', () async {
      final text = await callFirst(
          ToolSourceConfig(id: 'u', type: ToolSourceType.utcp, name: 'Phone', url: 'http://127.0.0.1:${host.port}/utcp'),
          {'_tool': 'chat', 'request': {'prompt': 'via utcp'}});
      expect(jsonDecode(text)['text'], 'host got: via utcp');
    });

    test('A2A', () async {
      final text = await callFirst(
          ToolSourceConfig(id: 'a', type: ToolSourceType.a2a, name: 'Phone', url: 'http://127.0.0.1:${host.port}'),
          {'_tool': 'ask', 'message': 'via a2a'});
      expect(text, 'host got: via a2a');
    });

    test('wrong key is reported', () async {
      final c = ToolSourceConfig(id: 'm', type: ToolSourceType.mcp, name: 'Phone', url: 'http://127.0.0.1:${host.mcpPort}/mcp');
      await registry.addOrUpdate(c, secret: 'cbh_wrong');
      expect(registry.status['m']!.error, isNotNull);
      expect(registry.activeTools(), isEmpty);
    });
  });

  group('CLI', () {
    test('program names', () {
      expect(programOf('git status'), 'git');
      expect(programOf(r'"C:\Program Files\Git\bin\git.exe" log'), 'git');
      expect(programOf('/usr/bin/python3 -c x'), 'python3');
    });

    test('allowlisted program runs; output and exit code returned', () async {
      final r = await runProcess('echo', ['hello world']);
      expect(r.text, contains('hello world'));
      expect(r.text, contains('Exit code: 0'));
      final missing = await runProcess('definitely-not-a-program-xyz', []);
      expect(missing.isError, isTrue);
    }, skip: !cliSupported);

    test('UTCP CLI tools need allowlisted programs and run as one script', () async {
      final manual = {
        'utcp_version': '1.0.1',
        'tools': [
          {
            'name': 'greet',
            'description': 'Greets',
            'inputs': {'type': 'object', 'properties': {'who': {'type': 'string'}}},
            'tool_call_template': {
              'call_template_type': 'cli',
              'commands': [
                {'command': 'echo UTCP_ARG_who_UTCP_END'},
                {'command': r'echo "got: $CMD_0_OUTPUT"', 'append_to_final_output': true},
              ],
            },
          },
          {
            'name': 'danger',
            'description': 'x',
            'tool_call_template': {'call_template_type': 'cli', 'commands': [{'command': 'rm -rf /tmp/x'}]},
          },
          {'name': 'ws', 'description': 'x', 'tool_call_template': {'call_template_type': 'websocket'}},
        ],
      };
      final client = MockClient((_) async => http.Response(jsonEncode(manual), 200));
      final source = UtcpToolSource(
          ToolSourceConfig(id: 'u', type: ToolSourceType.utcp, name: 'x', url: 'http://m/utcp'), null,
          allowedPrograms: {}, client: client);
      final tools = await source.discover();
      expect(tools.map((t) => t.name), ['greet']); // echo is a built-in; rm is not allowed
      expect(tools.single.alwaysAsk, isTrue);
      expect(source.skipped.join(), allOf(contains('"rm"'), contains('websocket')));
      final out = await source.call('greet', {'who': "it's me"});
      expect(out.text, contains("got: it's me"));
    }, skip: !cliSupported);
  });
}

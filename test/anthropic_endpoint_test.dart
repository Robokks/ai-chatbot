import 'dart:convert';
import 'dart:io';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class MessagesBackend implements HostBackend {
  final requests = <ChatRequest>[];
  @override String get deviceName => 'Main';
  @override List<SharedModel> sharedModels() => const [SharedModel(ProviderKind.openai, 'test'),
    SharedModel(ProviderKind.anthropic, 'test'), SharedModel(ProviderKind.gemini, 'test')];
  @override LlmProvider providerFor(ProviderKind kind) => MessagesFake(this, kind);
}
class MessagesFake extends LlmProvider {
  MessagesFake(this.backend, ProviderKind kind) : super(settings: ProviderSettings(kind: kind), apiKey: 'test');
  final MessagesBackend backend;
  @override Stream<ChatDelta> streamChat(ChatRequest request) async* {
    backend.requests.add(request);
    if (request.messages.last.role == Role.tool) {
      if (kind == ProviderKind.gemini) {
        expect(request.messages[1].provider, ProviderKind.gemini);
        expect(request.messages[1].providerBlocks!.first['thoughtSignature'], 'gemini-signature');
      }
      yield const ChatDelta(text: 'Tool finished');
    } else if (request.tools.isNotEmpty) {
      yield ChatDelta(toolCalls: [ToolCall(id: 't1', name: request.tools.first.name, arguments: {'x': 1})],
        providerBlocks: kind == ProviderKind.gemini ? [{'thoughtSignature': 'gemini-signature', 'functionCall': {'name': request.tools.first.name}}] : null);
    } else {
      yield ChatDelta(text: 'Hello', providerBlocks: kind == ProviderKind.anthropic
          ? [{'type': 'thinking', 'thinking': 'Thought', 'signature': 'native-signature'}, {'type': 'text', 'text': 'Hello'}] : null);
    }
    yield ChatDelta(usage: UsageStats(inputTokens: 20, outputTokens: 5));
  }
  @override Future<List<String>> listModels() async => [];
}
void main() {
  late HostServer server;
  late MessagesBackend backend;
  late PairedDevice device;
  late HttpClient http;
  Future<(int, String)> call(Map body, {String? key}) async {
    final request = await http.postUrl(Uri.parse('http://127.0.0.1:${server.port}/v1/messages'));
    request.headers.set('x-api-key', key ?? device.key);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    return (response.statusCode, await utf8.decoder.bind(response).join());
  }
  Map body(String model, {bool stream = false}) => {'model': model, 'max_tokens': 128, 'stream': stream,
    'messages': [{'role': 'user', 'content': 'Hi'}]};
  setUp(() async {
    backend = MessagesBackend(); http = HttpClient();
    server = HostServer(backend, loadDevices: () async => [], saveDevices: (_) async {});
    await server.start(port: 0, address: InternetAddress.loopbackIPv4);
    device = await server.createKey('Client');
  });
  tearDown(() async { http.close(force: true); await server.stop(); });
  test('JSON and streaming Messages clients receive text, usage, output caps and native signatures', () async {
    final response = await call(body('openai/test'));
    expect(response.$1, 200);
    final json = jsonDecode(response.$2);
    expect(json['type'], 'message'); expect(json['content'][0]['text'], 'Hello');
    expect(json['usage'], {'input_tokens': 20, 'output_tokens': 5});
    expect(backend.requests.last.maxOutputTokens, 128);
    final stream = await call(body('anthropic/test', stream: true));
    expect(stream.$2, contains('event: message_start'));
    expect(stream.$2, contains('native-signature'));
    expect(stream.$2.indexOf('thinking_delta'), lessThan(stream.$2.indexOf('text_delta')));
    expect(stream.$2, contains('event: message_stop'));
    expect(device.usage.requests, 2);
  });
  test('client tool loops replay provider-specific state and cannot share it with another PC', () async {
    final first = body('gemini/test')..['tools'] = [{'name': 'get_time', 'input_schema': {'type': 'object'}}];
    final reply = jsonDecode((await call(first)).$2);
    expect(reply['stop_reason'], 'tool_use');
    final second = body('gemini/test')..['messages'] = [
      {'role': 'user', 'content': 'Hi'}, {'role': 'assistant', 'content': reply['content']},
      {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'Done'}]},
    ];
    expect((await call(second)).$1, 200);
    final other = await server.createKey('Another PC');
    expect((await call(second, key: other.key)).$1, 409);
  });
  test('the same key, model, service and tool policy applies to Messages requests', () async {
    expect((await call(body('openai/test'), key: 'bad')).$1, 401);
    await server.updateAccess(device, ClientAccess(models: {'anthropic/test'}, requestsPerDay: 1));
    expect((await call(body('openai/test'))).$1, 403);
    expect((await call(body('anthropic/test'))).$1, 200);
    final quota = await call(body('anthropic/test'));
    expect(quota.$1, 429); expect(jsonDecode(quota.$2)['type'], 'error');
  });
}

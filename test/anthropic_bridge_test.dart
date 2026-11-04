import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/anthropic_bridge.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Messages API maps system, images, PDFs and tool turns without losing signed thinking', () {
    final request = parseAnthropicRequest({'model': 'anthropic/test', 'max_tokens': 128,
      'system': [{'type': 'text', 'text': 'System'}], 'tools': [{'name': 'get_time', 'input_schema': {'type': 'object'}}],
      'messages': [
        {'role': 'user', 'content': [{'type': 'text', 'text': 'Hi'},
          {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'AQI='}},
          {'type': 'document', 'source': {'type': 'base64', 'media_type': 'application/pdf', 'data': 'JVBERg=='}}]},
        {'role': 'assistant', 'content': [{'type': 'thinking', 'thinking': 'Thought', 'signature': 'signed'},
          {'type': 'tool_use', 'id': 't1', 'name': 'get_time', 'input': {'x': 1}}]},
        {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'Done'}]},
      ]});
    expect(request.systemPrompt, 'System');
    expect(request.messages.first.attachments.map((a) => a.kind), [AttachmentKind.image, AttachmentKind.pdf]);
    expect(request.messages[1].provider, ProviderKind.anthropic);
    expect(request.messages[1].providerBlocks!.first['signature'], 'signed');
    expect(request.messages.last.toolResults.single.name, 'get_time');
    expect(request.tools.single.name, 'get_time');
  });
  test('SSE preserves thinking signatures, text and complete tool JSON', () {
    final events = [
      for (final (i, block) in <Map<String, dynamic>>[
        {'type': 'thinking', 'thinking': 'Thought', 'signature': 'signed'},
        {'type': 'text', 'text': 'Hello'},
        {'type': 'tool_use', 'id': 't1', 'name': 'run', 'input': {'x': 1}},
      ].indexed) ...anthropicBlockEvents(block, i)];
    expect(events.where((e) => e.event == 'content_block_start').map((e) => e.data['index']), [0, 1, 2]);
    expect(events.any((e) => e.data['delta']?['signature'] == 'signed'), isTrue);
    expect(events.any((e) => e.data['delta']?['partial_json'] == '{"x":1}'), isTrue);
    expect(events.last.event, 'content_block_stop');
  });
  test('replay keys bind to the PC, model, tool arguments and assistant text', () {
    final message = Message(role: Role.assistant, text: 'Hi', toolCalls: [ToolCall(id: 't1', name: 'tool', arguments: {'a': 1})]);
    final key = messageReplayKey('pc1', 'model1', message);
    expect(messageReplayKey('pc2', 'model1', message), isNot(key));
    expect(messageReplayKey('pc1', 'model2', message), isNot(key));
    message.text = 'Changed';
    expect(messageReplayKey('pc1', 'model1', message), isNot(key));
  });
  test('invalid limits, roles and tools fail clearly', () {
    expect(() => parseAnthropicRequest({'model': 'x', 'max_tokens': 0, 'messages': []}), throwsA(isA<BridgeException>()));
    expect(() => parseAnthropicRequest({'model': 'x', 'max_tokens': 1, 'messages': [{'role': 'system', 'content': 'bad'}]}), throwsA(isA<BridgeException>()));
    expect(() => parseAnthropicRequest({'model': 'x', 'max_tokens': 1, 'tools': [1], 'messages': []}), throwsA(isA<BridgeException>()));
  });
}

import 'dart:convert';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/openai_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('network clients receive actual selected provider and fallback attribution', () async {
    final writer = CompletionWriter('custom/auto:mixed');
    writer.add(const ChatDelta(providerKind: ProviderKind.groq, routingInfo: 'Answered by Groq · m · 1 fallbacks'));
    final text = writer.add(const ChatDelta(text: 'Hello'))!;
    final client = MockClient.streaming((_, _) async => http.StreamedResponse(
      Stream.value(utf8.encode('data: ${jsonEncode(text)}\n\ndata: ${jsonEncode(writer.finalChunk())}\n\ndata: [DONE]\n\n')), 200));
    final provider = OpenAiProvider(settings: ProviderSettings(kind: ProviderKind.network, baseUrl: 'http://main/v1'), apiKey: 'test', client: client);
    try {
      final deltas = await provider.streamChat(ChatRequest(model: writer.model, messages: [Message(role: Role.user, text: 'Hi')])).toList();
      expect(deltas.map((d) => d.text).join(), 'Hello');
      expect(deltas.map((d) => d.routingInfo).whereType<String>().single, contains('1 fallbacks'));
      expect(deltas.map((d) => d.providerKind).whereType<ProviderKind>().last, ProviderKind.groq);
    } finally { client.close(); }
  });
  test('ordinary tool replies preserve chosen backend format across generic chat replay', () {
    final writer = CompletionWriter('custom/auto:mixed');
    writer.add(ChatDelta(providerKind: ProviderKind.groq, toolCalls: [ToolCall(id: 'one', name: 'inspect', arguments: {})]));
    final assistant = ((writer.completion()['choices'] as List).single as Map)['message'];
    final parsed = parseChatRequest({'model': writer.model, 'messages': [
      {'role': 'user', 'content': 'Inspect'}, assistant,
      {'role': 'tool', 'tool_call_id': 'one', 'content': 'done'},
    ]});
    expect(parsed.messages[1].provider, ProviderKind.groq);
    expect(parsed.messages[1].providerBlocks, isEmpty);
  });
}

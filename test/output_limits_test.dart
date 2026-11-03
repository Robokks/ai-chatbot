import 'package:ai_chatbot/data/llm/anthropic_provider.dart';
import 'package:ai_chatbot/data/llm/gemini_provider.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/openai_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ChatRequest request({int? limit}) => ChatRequest(
    model: 'test-model', messages: [Message(role: Role.user, text: 'Hello')],
    maxOutputTokens: limit,
  );

  test('provider requests carry the server output limit in their native field', () {
    final anthropic = AnthropicProvider(settings: ProviderSettings(kind: ProviderKind.anthropic), apiKey: 'test');
    final google = GeminiProvider(settings: ProviderSettings(kind: ProviderKind.gemini), apiKey: 'test');
    expect(anthropic.buildBody(request(limit: 512))['max_tokens'], 512);
    expect(google.buildBody(request(limit: 512))['generationConfig'], {'maxOutputTokens': 512});
    for (final kind in [ProviderKind.openai, ProviderKind.deepseek, ProviderKind.custom, ProviderKind.network]) {
      final provider = OpenAiProvider(settings: ProviderSettings(kind: kind), apiKey: 'test');
      final body = provider.buildBody(request(limit: 512));
      expect(body[kind == ProviderKind.openai ? 'max_completion_tokens' : 'max_tokens'], 512);
    }
  });

  test('requests without a limit preserve previous provider defaults', () {
    final anthropic = AnthropicProvider(settings: ProviderSettings(kind: ProviderKind.anthropic), apiKey: 'test');
    final google = GeminiProvider(settings: ProviderSettings(kind: ProviderKind.gemini), apiKey: 'test');
    final openai = OpenAiProvider(settings: ProviderSettings(kind: ProviderKind.openai), apiKey: 'test');
    expect(anthropic.buildBody(request())['max_tokens'], 64000);
    expect(google.buildBody(request()).containsKey('generationConfig'), isFalse);
    expect(openai.buildBody(request()).containsKey('max_completion_tokens'), isFalse);
  });
}

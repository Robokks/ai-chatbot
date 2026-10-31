import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_chatbot/data/llm/anthropic_provider.dart';
import 'package:ai_chatbot/data/llm/gemini_provider.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/openai_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _png = Uint8List.fromList([1, 2, 3]);
final _pdf = Uint8List.fromList([4, 5, 6]);

List<Message> _history() => [
      Message(role: Role.user, text: 'Look at these', attachments: [
        Attachment(name: 'a.png', mimeType: 'image/png', kind: AttachmentKind.image, size: 3, bytes: _png),
        Attachment(name: 'r.pdf', mimeType: 'application/pdf', kind: AttachmentKind.pdf, size: 3, bytes: _pdf, text: 'PDF TEXT'),
        Attachment(name: 'n.txt', mimeType: 'text/plain', kind: AttachmentKind.text, size: 5, text: 'notes'),
      ]),
      Message(role: Role.assistant, text: 'Sure.'),
      Message(role: Role.assistant, text: ''), // in-progress reply is skipped
    ];

ChatRequest _req(String model) =>
    ChatRequest(model: model, messages: _history(), systemPrompt: 'Be brief');

http.StreamedResponse _sse(String body, {int status = 200}) =>
    http.StreamedResponse(Stream.value(utf8.encode(body)), status);

void main() {
  group('Anthropic', () {
    AnthropicProvider make([http.Client? c]) => AnthropicProvider(
        settings: ProviderSettings(kind: ProviderKind.anthropic), apiKey: 'k', client: c);

    test('builds content blocks for image, pdf and text', () {
      final body = make().buildBody(_req('claude-opus-5-5'));
      expect(body['system'], 'Be brief');
      expect(body['max_tokens'], 64000);
      expect(body.containsKey('temperature'), isFalse);
      expect(body['thinking'], {'type': 'adaptive', 'display': 'summarized'});
      expect(body['fallbacks'], 'default');
      final msgs = body['messages'] as List;
      expect(msgs, hasLength(2));
      final content = msgs[0]['content'] as List;
      expect(content[0]['type'], 'image');
      expect(content[0]['source']['data'], base64Encode(_png));
      expect(content[1]['type'], 'document');
      expect(content[1]['source']['media_type'], 'application/pdf');
      expect(content[2]['type'], 'text');
      expect(content[2]['text'], contains('notes'));
      expect(content[2]['text'], isNot(contains('PDF TEXT')));
      expect(msgs[1], {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Sure.'},
        ],
      });
    });

    test('omits thinking for older models', () {
      final body = make().buildBody(_req('claude-haiku-4-5'));
      expect(body.containsKey('thinking'), isFalse);
      expect(body.containsKey('fallbacks'), isFalse);
    });

    test('streams text and thinking deltas with correct headers', () async {
      late http.BaseRequest sent;
      final client = MockClient.streaming((req, _) async {
        sent = req;
        return _sse('event: content_block_delta\n'
            'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}\n\n'
            'event: content_block_delta\n'
            'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n'
            'event: message_delta\n'
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n');
      });
      final deltas = await make(client).streamChat(_req('claude-opus-5-5')).toList();
      expect(deltas.map((d) => d.reasoning).join(), 'hmm');
      expect(deltas.map((d) => d.text).join(), 'Hi');
      expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(sent.headers['x-api-key'], 'k');
      expect(sent.headers['anthropic-version'], '2026-10-21');
      expect(sent.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
    });

    test('reports token usage from message_start and message_delta', () async {
      final client = MockClient.streaming((_, _) async => _sse(
          'data: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":30,"output_tokens":1}}}\n\n'
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}\n\n'));
      final usage = UsageStats();
      await for (final d in make(client).streamChat(_req('claude-opus-5-5'))) {
        if (d.usage != null) usage.merge(d.usage!);
      }
      expect(usage.inputTokens, 150);
      expect(usage.cachedTokens, 30);
      expect(usage.outputTokens, 42);
    });

    test('surfaces API errors with a hint', () async {
      final client = MockClient.streaming((_, _) async => _sse(
          '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
          status: 401));
      expect(
        make(client).streamChat(_req('claude-opus-5-5')).toList(),
        throwsA(isA<LlmException>().having(
            (e) => e.message, 'message', allOf(contains('401'), contains('invalid x-api-key'), contains('API key')))),
      );
    });
  });

  group('OpenAI-compatible', () {
    OpenAiProvider make(ProviderKind kind, [http.Client? c]) =>
        OpenAiProvider(settings: ProviderSettings(kind: kind), apiKey: 'k', client: c);

    test('OpenAI gets image_url and file parts', () {
      final body = make(ProviderKind.openai).buildBody(_req('gpt-5'));
      final msgs = body['messages'] as List;
      expect(msgs[0], {'role': 'system', 'content': 'Be brief'});
      final parts = msgs[1]['content'] as List;
      expect(parts[0]['type'], 'image_url');
      expect(parts[0]['image_url']['url'], startsWith('data:image/png;base64,'));
      expect(parts[1]['type'], 'file');
      expect(parts[2]['type'], 'text');
    });

    test('DeepSeek gets plain text with extracted PDF text and no image', () {
      final body = make(ProviderKind.deepseek).buildBody(_req('deepseek-chat'));
      final user = (body['messages'] as List)[1];
      expect(user['content'], isA<String>());
      expect(user['content'], contains('PDF TEXT'));
      expect(user['content'], contains('notes'));
      expect(user['content'], contains('Look at these'));
    });

    test('asks for usage only where supported and reads it', () async {
      expect(make(ProviderKind.openai).buildBody(_req('gpt-5'))['stream_options'],
          {'include_usage': true});
      expect(make(ProviderKind.custom).buildBody(_req('llama3'))['stream_options'], isNull);
      expect(make(ProviderKind.groq).buildBody(_req('llama'))['stream_options'], isNull);

      final client = MockClient.streaming((_, _) async => _sse(
          'data: {"choices":[{"delta":{"content":"Yo"}}]}\n\n'
          'data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":4}}}\n\n'
          'data: [DONE]\n\n'));
      final usage = UsageStats();
      await for (final d in make(ProviderKind.openai, client).streamChat(_req('gpt-5'))) {
        if (d.usage != null) usage.merge(d.usage!);
      }
      expect(usage.inputTokens, 11);
      expect(usage.outputTokens, 3);
      expect(usage.cachedTokens, 4);
    });

    test('streams content and reasoning_content', () async {
      final client = MockClient.streaming((req, _) async {
        expect(req.headers['authorization'], 'Bearer k');
        expect(req.url.toString(), 'https://api.deepseek.com/v1/chat/completions');
        return _sse('data: {"choices":[{"delta":{"reasoning_content":"think"}}]}\n\n'
            'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n'
            'data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n');
      });
      final deltas =
          await make(ProviderKind.deepseek, client).streamChat(_req('deepseek-reasoner')).toList();
      expect(deltas.map((d) => d.text).join(), 'Hello');
      expect(deltas.map((d) => d.reasoning).join(), 'think');
    });
  });

  group('Gemini', () {
    test('maps roles and inline data', () {
      final p = GeminiProvider(settings: ProviderSettings(kind: ProviderKind.gemini), apiKey: 'k');
      final body = p.buildBody(_req('gemini-2.5-pro'));
      final contents = body['contents'] as List;
      expect(contents[0]['role'], 'user');
      expect((contents[0]['parts'] as List).first['inline_data']['mime_type'], 'image/png');
      expect(contents[1]['role'], 'model');
      expect(body['systemInstruction']['parts'][0]['text'], 'Be brief');
    });
  });
}

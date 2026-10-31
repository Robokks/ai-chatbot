import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'llm_provider.dart';
import 'sse.dart';

/// OpenAI Chat Completions, also used for DeepSeek, OpenRouter, Groq and any
/// OpenAI-compatible server (Ollama, LM Studio, vLLM...).
class OpenAiProvider extends LlmProvider {
  OpenAiProvider({required super.settings, required super.apiKey, super.client});

  bool get _reportsUsage => const {
        ProviderKind.openai,
        ProviderKind.deepseek,
        ProviderKind.openrouter,
      }.contains(kind);

  Map<String, String> get _headers => {
        if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
        'content-type': 'application/json',
      };

  Map<String, dynamic> buildBody(ChatRequest req) {
    final messages = <Map<String, dynamic>>[
      if (req.systemPrompt?.trim().isNotEmpty ?? false)
        {'role': 'system', 'content': req.systemPrompt!.trim()},
    ];
    for (final m in req.messages) {
      if (m.role == Role.assistant) {
        if (m.text.isEmpty) continue;
        messages.add({'role': 'assistant', 'content': m.text});
        continue;
      }
      final images = kind.images
          ? m.attachments
              .where((a) => a.kind == AttachmentKind.image && a.bytes != null)
          : const <Attachment>[];
      final pdfs = kind.pdf
          ? m.attachments
              .where((a) => a.kind == AttachmentKind.pdf && a.bytes != null)
          : const <Attachment>[];
      final text = inlineTextAttachments(m, includePdf: !kind.pdf);

      if (images.isEmpty && pdfs.isEmpty) {
        if (text.isEmpty) continue;
        messages.add({'role': 'user', 'content': text});
        continue;
      }
      messages.add({
        'role': 'user',
        'content': [
          for (final a in images)
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:${a.mimeType};base64,${base64Encode(a.bytes!)}'
              },
            },
          for (final a in pdfs)
            {
              'type': 'file',
              'file': {
                'filename': a.name,
                'file_data':
                    'data:application/pdf;base64,${base64Encode(a.bytes!)}',
              },
            },
          if (text.isNotEmpty) {'type': 'text', 'text': text},
        ],
      });
    }
    return {
      'model': req.model,
      'stream': true,
      'messages': messages,
      // Ask for token counts in the final event. Custom servers and Groq may
      // reject unknown options, so only send it where it is supported.
      if (_reportsUsage) 'stream_options': {'include_usage': true},
    };
  }

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    final req = http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(request));
    final res = await send(req);

    await for (final ev in parseSse(res.stream)) {
      if (ev.data.isEmpty || ev.data == '[DONE]') continue;
      final Map<String, dynamic> j = jsonDecode(ev.data);
      if (j['error'] != null) {
        throw LlmException(
            (j['error'] as Map)['message']?.toString() ?? 'Stream error');
      }
      final u = j['usage'] as Map?;
      if (u != null) {
        yield ChatDelta(
          usage: UsageStats(
            inputTokens: u['prompt_tokens'] as int?,
            outputTokens: u['completion_tokens'] as int?,
            cachedTokens: ((u['prompt_tokens_details'] as Map?)?['cached_tokens'] ??
                u['prompt_cache_hit_tokens']) as int?,
          ),
        );
      }
      final choices = j['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;
      final delta = choice['delta'] as Map<String, dynamic>? ?? const {};
      final text = delta['content'] as String? ?? '';
      // DeepSeek-reasoner / OpenRouter expose reasoning separately.
      final reasoning = (delta['reasoning_content'] ?? delta['reasoning'])
              as String? ??
          '';
      if (text.isNotEmpty || reasoning.isNotEmpty) {
        yield ChatDelta(text: text, reasoning: reasoning);
      }
      if (choice['finish_reason'] == 'length') {
        yield const ChatDelta(notice: 'Response hit the length limit.');
      } else if (choice['finish_reason'] == 'content_filter') {
        yield const ChatDelta(notice: 'The provider filtered this response.');
      }
    }
  }

  @override
  Future<List<String>> listModels() async {
    final res = await send(
        http.Request('GET', Uri.parse('$baseUrl/models'))..headers.addAll(_headers));
    final j = jsonDecode(await res.stream.bytesToString());
    final ids = [for (final m in j['data'] as List) m['id'] as String]..sort();
    return ids;
  }
}

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'llm_provider.dart';
import 'sse.dart';

/// Claude via the Messages API (raw HTTP; there is no official Dart SDK).
class AnthropicProvider extends LlmProvider {
  AnthropicProvider({required super.settings, required super.apiKey, super.client});

  static const apiVersion = '2026-10-21';
  static const _fallbackBeta = 'server-side-fallback-2026-07-01';

  /// Models that accept server-side refusal fallbacks (`fallbacks: "default"`).
  static const _fallbackModels = {
    'claude-fable-5-1',
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-sonnet-5-5',
  };

  /// Models that support adaptive thinking (Claude 4.6 and later).
  static final _adaptiveThinking =
      RegExp(r'^claude-(opus|sonnet|haiku|fable|mythos)-([5-9]|4-[6-9])');

  Map<String, String> get _headers => {
        'x-api-key': apiKey,
        'anthropic-version': apiVersion,
        'content-type': 'application/json',
        // Lets the web build call the API from a browser.
        'anthropic-dangerous-direct-browser-access': 'true',
      };

  bool _usesFallbacks(String model) =>
      _fallbackModels.contains(model) && baseUrl.contains('api.anthropic.com');

  Map<String, dynamic> buildBody(ChatRequest req) {
    final messages = <Map<String, dynamic>>[];
    for (final m in req.messages) {
      if (m.role == Role.assistant) {
        if (m.text.isEmpty) continue;
        messages.add({'role': 'assistant', 'content': m.text});
        continue;
      }
      final content = <Map<String, dynamic>>[];
      for (final a in m.attachments) {
        if (a.bytes == null) continue;
        if (a.kind == AttachmentKind.image) {
          content.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': a.mimeType,
              'data': base64Encode(a.bytes!),
            },
          });
        } else if (a.kind == AttachmentKind.pdf) {
          content.add({
            'type': 'document',
            'title': a.name,
            'source': {
              'type': 'base64',
              'media_type': 'application/pdf',
              'data': base64Encode(a.bytes!),
            },
          });
        }
      }
      final text = inlineTextAttachments(m, includePdf: false);
      if (text.isNotEmpty) content.add({'type': 'text', 'text': text});
      if (content.isEmpty) continue;
      messages.add({'role': 'user', 'content': content});
    }

    return {
      'model': req.model,
      'max_tokens': 64000,
      'stream': true,
      'messages': messages,
      if (req.systemPrompt?.trim().isNotEmpty ?? false)
        'system': req.systemPrompt!.trim(),
      if (_adaptiveThinking.hasMatch(req.model))
        'thinking': {'type': 'adaptive', 'display': 'summarized'},
      if (_usesFallbacks(req.model)) 'fallbacks': 'default',
    };
  }

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    final req = http.Request('POST', Uri.parse('$baseUrl/messages'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(request));
    if (_usesFallbacks(request.model)) {
      req.headers['anthropic-beta'] = _fallbackBeta;
    }
    final res = await send(req);

    await for (final ev in parseSse(res.stream)) {
      if (ev.data.isEmpty) continue;
      final Map<String, dynamic> j = jsonDecode(ev.data);
      switch (j['type']) {
        case 'message_start':
          final u = (j['message'] as Map?)?['usage'] as Map?;
          if (u != null) {
            yield ChatDelta(
              usage: UsageStats(
                inputTokens: (u['input_tokens'] as int? ?? 0) +
                    (u['cache_creation_input_tokens'] as int? ?? 0) +
                    (u['cache_read_input_tokens'] as int? ?? 0),
                cachedTokens: u['cache_read_input_tokens'] as int?,
                outputTokens: u['output_tokens'] as int?,
              ),
            );
          }
        case 'content_block_delta':
          final d = j['delta'] as Map<String, dynamic>;
          if (d['type'] == 'text_delta') {
            yield ChatDelta(text: d['text'] as String);
          } else if (d['type'] == 'thinking_delta') {
            yield ChatDelta(reasoning: d['thinking'] as String);
          }
        case 'message_delta':
          final out = (j['usage'] as Map?)?['output_tokens'] as int?;
          if (out != null) yield ChatDelta(usage: UsageStats(outputTokens: out));
          final stop = (j['delta'] as Map?)?['stop_reason'];
          if (stop == 'refusal') {
            yield const ChatDelta(
                notice: 'Claude declined to continue this response.');
          } else if (stop == 'max_tokens') {
            yield const ChatDelta(notice: 'Response hit the length limit.');
          }
        case 'error':
          throw LlmException(
              (j['error'] as Map?)?['message']?.toString() ?? 'Stream error');
      }
    }
  }

  @override
  Future<List<String>> listModels() async {
    final res = await send(
        http.Request('GET', Uri.parse('$baseUrl/models?limit=100'))
          ..headers.addAll(_headers));
    final j = jsonDecode(await res.stream.bytesToString());
    return [for (final m in j['data'] as List) m['id'] as String];
  }
}

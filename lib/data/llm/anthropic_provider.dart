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
        final content = _assistantContent(m);
        if (content.isNotEmpty) messages.add({'role': 'assistant', 'content': content});
        continue;
      }
      if (m.role == Role.tool) {
        messages.add({
          'role': 'user',
          'content': [
            for (final r in m.toolResults)
              {
                'type': 'tool_result',
                'tool_use_id': r.callId,
                'content': r.text.isEmpty ? '(no output)' : r.text,
                if (r.isError) 'is_error': true,
              },
          ],
        });
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
      if (req.tools.isNotEmpty)
        'tools': [
          for (final t in req.tools)
            {'name': t.name, 'description': t.description, 'input_schema': t.inputSchema},
        ],
      if (_adaptiveThinking.hasMatch(req.model))
        'thinking': {'type': 'adaptive', 'display': 'summarized'},
      if (_usesFallbacks(req.model)) 'fallbacks': 'default',
    };
  }

  /// Assistant turn content. A turn that used tools replays Claude's own
  /// blocks unchanged (thinking blocks carry signatures the API checks).
  static List<Map<String, dynamic>> _assistantContent(Message m) {
    final raw = m.providerBlocks;
    if (raw != null && m.provider == ProviderKind.anthropic) {
      return [
        for (final b in raw)
          if (!(b['type'] == 'text' && (b['text'] as String? ?? '').isEmpty)) b,
      ];
    }
    return [
      if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
      for (final c in m.toolCalls)
        {'type': 'tool_use', 'id': c.id, 'name': c.name, 'input': c.arguments},
    ];
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

    // Content blocks of this turn, rebuilt from the stream so a tool turn
    // can be replayed exactly.
    final blocks = <int, Map<String, dynamic>>{};
    final toolJson = <int, StringBuffer>{};
    var usedTools = false;

    await for (final ev in parseSse(res.stream)) {
      if (ev.data.isEmpty) continue;
      final Map<String, dynamic> j = jsonDecode(ev.data);
      final index = j['index'] as int?;
      switch (j['type']) {
        case 'content_block_start':
          final b = Map<String, dynamic>.from(j['content_block'] as Map);
          if (b['type'] == 'tool_use') {
            b['input'] = <String, dynamic>{};
            toolJson[index!] = StringBuffer();
          }
          if (b['type'] == 'thinking') b['signature'] ??= '';
          blocks[index!] = b;
        case 'content_block_stop':
          final b = blocks[index];
          if (b != null && b['type'] == 'tool_use') {
            final args = decodeToolArgs(toolJson[index]!.toString());
            b['input'] = args;
            usedTools = true;
            yield ChatDelta(toolCalls: [
              ToolCall(id: b['id'] as String, name: b['name'] as String, arguments: args),
            ]);
          }
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
          final b = blocks[index];
          switch (d['type']) {
            case 'text_delta':
              if (b != null) b['text'] = '${b['text'] ?? ''}${d['text']}';
              yield ChatDelta(text: d['text'] as String);
            case 'thinking_delta':
              if (b != null) b['thinking'] = '${b['thinking'] ?? ''}${d['thinking']}';
              yield ChatDelta(reasoning: d['thinking'] as String);
            case 'signature_delta':
              if (b != null) b['signature'] = '${b['signature'] ?? ''}${d['signature']}';
            case 'input_json_delta':
              toolJson[index]?.write(d['partial_json'] as String? ?? '');
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
    if (usedTools) {
      final keys = blocks.keys.toList()..sort();
      yield ChatDelta(providerBlocks: [for (final k in keys) blocks[k]!]);
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

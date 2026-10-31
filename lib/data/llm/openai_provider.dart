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
        ProviderKind.network,
      }.contains(kind);

  /// A home-server turn stores `[{x_provider: name}, ...blocks]`; send them
  /// back the way the host's bridge expects.
  static Map<String, dynamic> _hostBlocksFields(List<Map<String, dynamic>> stored) {
    final marker = stored.isNotEmpty && stored.first.keys.every((k) => k == 'x_provider');
    return {
      'x_provider': marker ? stored.first['x_provider'] : null,
      'x_provider_blocks': marker ? stored.sublist(1) : stored,
    };
  }

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
        if (m.text.isEmpty && m.toolCalls.isEmpty) continue;
        messages.add({
          'role': 'assistant',
          'content': m.text.isEmpty ? null : m.text,
          if (kind == ProviderKind.network && m.providerBlocks != null)
            ..._hostBlocksFields(m.providerBlocks!),
          // DeepSeek's thinking mode needs its reasoning back during a tool loop.
          if (kind == ProviderKind.deepseek && m.toolCalls.isNotEmpty && m.reasoning.isNotEmpty)
            'reasoning_content': m.reasoning,
          if (m.toolCalls.isNotEmpty)
            'tool_calls': [
              for (final c in m.toolCalls)
                {
                  'id': c.id,
                  'type': 'function',
                  'function': {'name': c.name, 'arguments': jsonEncode(c.arguments)},
                },
            ],
        });
        continue;
      }
      if (m.role == Role.tool) {
        for (final r in m.toolResults) {
          messages.add({
            'role': 'tool',
            'tool_call_id': r.callId,
            'content': r.isError ? 'Error: ${r.text}' : (r.text.isEmpty ? '(no output)' : r.text),
          });
        }
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
      if (req.tools.isNotEmpty)
        'tools': [
          for (final t in req.tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.inputSchema,
              },
            },
        ],
    };
  }

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    final req = http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(request));
    final res = await send(req);

    // Tool calls stream in pieces keyed by index.
    final calls = <int, ({String? id, StringBuffer name, StringBuffer args})>{};
    ProviderKind? hostProvider;
    List<Map<String, dynamic>>? hostBlocks;

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
      final blocks = delta['x_provider_blocks'];
      if (kind == ProviderKind.network && blocks is List) {
        hostProvider = ProviderKind.values.asNameMap()[delta['x_provider']];
        hostBlocks = [for (final b in blocks) Map<String, dynamic>.from(b as Map)];
      }
      final text = delta['content'] as String? ?? '';
      // DeepSeek-reasoner / OpenRouter expose reasoning separately.
      final reasoning = (delta['reasoning_content'] ?? delta['reasoning'])
              as String? ??
          '';
      if (text.isNotEmpty || reasoning.isNotEmpty) {
        yield ChatDelta(text: text, reasoning: reasoning);
      }
      for (final tc in delta['tool_calls'] as List? ?? const []) {
        final i = (tc as Map)['index'] as int? ?? calls.length;
        final f = tc['function'] as Map? ?? const {};
        final entry = calls[i] ??= (id: tc['id'] as String?, name: StringBuffer(), args: StringBuffer());
        if (entry.id == null && tc['id'] != null) {
          calls[i] = (id: tc['id'] as String, name: entry.name, args: entry.args);
        }
        if (f['name'] is String) calls[i]!.name.write(f['name']);
        if (f['arguments'] is String) calls[i]!.args.write(f['arguments']);
      }
      if (choice['finish_reason'] == 'length') {
        yield const ChatDelta(notice: 'Response hit the length limit.');
      } else if (choice['finish_reason'] == 'content_filter') {
        yield const ChatDelta(notice: 'The provider filtered this response.');
      }
    }
    if (calls.isNotEmpty) {
      final keys = calls.keys.toList()..sort();
      yield ChatDelta(
          providerBlocks: hostBlocks == null ? null : [
            {'x_provider': hostProvider?.name},
            ...hostBlocks,
          ],
          toolCalls: [
        for (final k in keys)
          if (calls[k]!.name.isNotEmpty)
            ToolCall(
              id: calls[k]!.id ?? 'call_$k',
              name: calls[k]!.name.toString(),
              arguments: decodeToolArgs(calls[k]!.args.toString()),
            ),
      ]);
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

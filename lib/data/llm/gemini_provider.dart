import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'llm_provider.dart';
import 'sse.dart';

/// Google Gemini via the Generative Language API.
class GeminiProvider extends LlmProvider {
  GeminiProvider({required super.settings, required super.apiKey, super.client});

  Map<String, String> get _headers => {
        'x-goog-api-key': apiKey,
        'content-type': 'application/json',
      };

  Map<String, dynamic> buildBody(ChatRequest req) {
    final contents = <Map<String, dynamic>>[];
    for (final m in req.messages) {
      if (m.role == Role.assistant) {
        // A tool turn replays Gemini's own parts (they carry thought signatures).
        final raw = m.provider == ProviderKind.gemini ? m.providerBlocks : null;
        final parts = raw ??
            [
              if (m.text.isNotEmpty) {'text': m.text},
              for (final c in m.toolCalls)
                {
                  'functionCall': {'name': c.name, 'args': c.arguments},
                },
            ];
        if (parts.isEmpty) continue;
        contents.add({'role': 'model', 'parts': parts});
        continue;
      }
      if (m.role == Role.tool) {
        contents.add({
          'role': 'user',
          'parts': [
            for (final r in m.toolResults)
              {
                'functionResponse': {
                  'name': r.name,
                  'response': r.isError ? {'error': r.text} : {'result': r.text},
                },
              },
          ],
        });
        continue;
      }
      final parts = <Map<String, dynamic>>[
        for (final a in m.attachments)
          if (a.bytes != null &&
              (a.kind == AttachmentKind.image || a.kind == AttachmentKind.pdf))
            {
              'inline_data': {
                'mime_type': a.mimeType,
                'data': base64Encode(a.bytes!),
              },
            },
      ];
      final text = inlineTextAttachments(m, includePdf: false);
      if (text.isNotEmpty) parts.add({'text': text});
      if (parts.isEmpty) continue;
      contents.add({'role': 'user', 'parts': parts});
    }
    return {
      'contents': contents,
      if (req.tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final t in req.tools)
                {
                  'name': t.name,
                  'description': t.description,
                  'parametersJsonSchema': t.inputSchema,
                },
            ],
          },
        ],
      if (req.systemPrompt?.trim().isNotEmpty ?? false)
        'systemInstruction': {
          'parts': [
            {'text': req.systemPrompt!.trim()}
          ],
        },
    };
  }

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    final uri = Uri.parse(
        '$baseUrl/models/${request.model}:streamGenerateContent?alt=sse');
    final req = http.Request('POST', uri)
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(request));
    final res = await send(req);

    final modelParts = <Map<String, dynamic>>[];
    final calls = <ToolCall>[];

    await for (final ev in parseSse(res.stream)) {
      if (ev.data.isEmpty) continue;
      final Map<String, dynamic> j = jsonDecode(ev.data);
      final u = j['usageMetadata'] as Map?;
      if (u != null) {
        yield ChatDelta(
          usage: UsageStats(
            inputTokens: u['promptTokenCount'] as int?,
            outputTokens: (u['candidatesTokenCount'] as int? ?? 0) +
                (u['thoughtsTokenCount'] as int? ?? 0),
            cachedTokens: u['cachedContentTokenCount'] as int?,
          ),
        );
      }
      final candidates = j['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) continue;
      final c = candidates.first as Map<String, dynamic>;
      final parts = (c['content'] as Map?)?['parts'] as List? ?? const [];
      for (final p in parts) {
        modelParts.add(Map<String, dynamic>.from(p as Map));
        final fc = p['functionCall'] as Map?;
        if (fc != null) {
          calls.add(ToolCall(
            id: fc['id'] as String? ?? 'call_${calls.length}',
            name: fc['name'] as String,
            arguments: Map<String, dynamic>.from(fc['args'] as Map? ?? const {}),
          ));
          continue;
        }
        final t = p['text'] as String?;
        if (t == null) continue;
        yield p['thought'] == true ? ChatDelta(reasoning: t) : ChatDelta(text: t);
      }
      if (c['finishReason'] == 'MAX_TOKENS') {
        yield const ChatDelta(notice: 'Response hit the length limit.');
      } else if (c['finishReason'] == 'SAFETY') {
        yield const ChatDelta(notice: 'Gemini blocked this response.');
      }
    }
    if (calls.isNotEmpty) {
      yield ChatDelta(toolCalls: calls, providerBlocks: _mergeText(modelParts));
    }
  }

  /// Streamed text arrives as many small parts; join neighbours so the
  /// replayed turn stays compact (parts with signatures stay as they are).
  static List<Map<String, dynamic>> _mergeText(List<Map<String, dynamic>> parts) {
    final out = <Map<String, dynamic>>[];
    for (final p in parts) {
      final last = out.isEmpty ? null : out.last;
      final plain = p.keys.every((k) => k == 'text' || k == 'thought');
      if (plain &&
          last != null &&
          last.keys.every((k) => k == 'text' || k == 'thought') &&
          last['thought'] == p['thought'] &&
          p['text'] is String) {
        last['text'] = '${last['text']}${p['text']}';
      } else {
        out.add(Map<String, dynamic>.from(p));
      }
    }
    return out;
  }

  @override
  Future<List<String>> listModels() async {
    final res = await send(
        http.Request('GET', Uri.parse('$baseUrl/models?pageSize=200'))
          ..headers.addAll(_headers));
    final j = jsonDecode(await res.stream.bytesToString());
    return [
      for (final m in j['models'] as List)
        if ((m['supportedGenerationMethods'] as List?)
                ?.contains('generateContent') ??
            false)
          (m['name'] as String).replaceFirst('models/', ''),
    ];
  }
}

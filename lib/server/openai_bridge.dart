import 'dart:convert';
import 'dart:typed_data';

import '../data/llm/llm_provider.dart';
import '../data/models.dart';

/// A model the host offers to other devices, e.g. `local/LFM2-1.2B-Q4_K_M`
/// or `anthropic/claude-sonnet-5-5`.
class SharedModel {
  const SharedModel(this.kind, this.model, {this.displayName});

  final ProviderKind kind;
  final String model;
  final String? displayName;

  String get id => '${kind.name}/$model';

  /// Splits an id like `anthropic/claude-sonnet-5-5`; null if malformed.
  static (ProviderKind, String)? parseId(String id) {
    final slash = id.indexOf('/');
    if (slash <= 0 || slash == id.length - 1) return null;
    final kind = ProviderKind.values.asNameMap()[id.substring(0, slash)];
    return kind == null ? null : (kind, id.substring(slash + 1));
  }
}

class BridgeException implements Exception {
  BridgeException(this.message, {this.status = 400, this.code = 'invalid_request'});
  final String message;
  final int status;
  final String code;

  Map<String, dynamic> toJson() => {
        'error': {'message': message, 'type': 'invalid_request_error', 'code': code},
      };

  @override
  String toString() => message;
}

/// An OpenAI chat-completions request translated for the app's providers.
class BridgedRequest {
  const BridgedRequest({
    required this.modelId,
    required this.messages,
    required this.systemPrompt,
    required this.stream,
    required this.includeUsage,
    this.tools = const [],
  });

  final List<ToolSpec> tools;
  final String modelId;
  final List<Message> messages;
  final String? systemPrompt;
  final bool stream;
  final bool includeUsage;
}

/// Parses an OpenAI `/v1/chat/completions` body. Images given as `data:`
/// URLs become attachments; remote image URLs are ignored for safety.
BridgedRequest parseChatRequest(Map<String, dynamic> body) {
  final model = body['model'];
  if (model is! String || model.isEmpty) throw BridgeException('"model" is required');
  final raw = body['messages'];
  if (raw is! List || raw.isEmpty) throw BridgeException('"messages" must be a non-empty list');

  final system = <String>[];
  final messages = <Message>[];
  final callNames = <String, String>{};
  for (final m in raw) {
    if (m is! Map) throw BridgeException('Each message must be an object');
    final role = m['role'];
    final content = m['content'];
    switch (role) {
      case 'system' || 'developer':
        final t = _text(content);
        if (t.isNotEmpty) system.add(t);
      case 'assistant':
        final calls = <ToolCall>[
          for (final c in m['tool_calls'] as List? ?? const [])
            if (c is Map && c['function'] is Map)
              ToolCall(
                id: c['id'] as String? ?? 'call_${callNames.length}',
                name: (c['function'] as Map)['name'] as String,
                arguments: decodeToolArgs((c['function'] as Map)['arguments'] as String? ?? ''),
              ),
        ];
        for (final c in calls) {
          callNames[c.id] = c.name;
        }
        // Raw provider blocks sent back by a Chatbot client (see CompletionWriter).
        final blocks = m['x_provider_blocks'];
        messages.add(Message(
          role: Role.assistant,
          text: _text(content),
          toolCalls: calls,
          provider: ProviderKind.values.asNameMap()[m['x_provider']],
          providerBlocks: blocks is List
              ? [for (final b in blocks) Map<String, dynamic>.from(b as Map)]
              : null,
        ));
      case 'user':
        messages.add(Message(
          role: Role.user,
          text: _text(content),
          attachments: _images(content),
        ));
      case 'tool':
        final id = m['tool_call_id'] as String? ?? '';
        final result = ToolResult(callId: id, name: callNames[id] ?? 'tool', text: _text(content));
        // Consecutive results belong to the same assistant turn.
        if (messages.isNotEmpty && messages.last.role == Role.tool) {
          messages.last.toolResults.add(result);
        } else {
          messages.add(Message(role: Role.tool, toolResults: [result]));
        }
      default:
        throw BridgeException('Unsupported message role "$role"');
    }
  }
  if (!messages.any((m) => m.role == Role.user)) {
    throw BridgeException('At least one user message is required');
  }
  final streamOptions = body['stream_options'];
  final tools = <ToolSpec>[
    for (final t in body['tools'] as List? ?? const [])
      if (t is Map && t['type'] == 'function' && t['function'] is Map)
        ToolSpec(
          name: (t['function'] as Map)['name'] as String,
          description: (t['function'] as Map)['description'] as String? ?? '',
          inputSchema: Map<String, dynamic>.from(
              (t['function'] as Map)['parameters'] as Map? ?? {'type': 'object', 'properties': {}}),
          sourceId: 'client',
          sourceLabel: 'Client',
        ),
  ];
  return BridgedRequest(
    tools: tools,
    modelId: model,
    messages: messages,
    systemPrompt: system.isEmpty ? null : system.join('\n\n'),
    stream: body['stream'] == true,
    includeUsage: streamOptions is Map && streamOptions['include_usage'] == true,
  );
}

String _text(Object? content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    return [
      for (final p in content)
        if (p is Map && p['type'] == 'text' && p['text'] is String) p['text'] as String,
    ].join('\n');
  }
  throw BridgeException('Unsupported message content');
}

final _dataUrl = RegExp(r'^data:(image/[a-zA-Z0-9.+-]+);base64,(.+)$', dotAll: true);

List<Attachment> _images(Object? content) {
  if (content is! List) return const [];
  final out = <Attachment>[];
  for (final p in content) {
    if (p is! Map || p['type'] != 'image_url') continue;
    final url = (p['image_url'] as Map?)?['url'];
    final match = url is String ? _dataUrl.firstMatch(url) : null;
    if (match == null) continue;
    final Uint8List bytes;
    try {
      bytes = base64Decode(match.group(2)!.trim());
    } catch (_) {
      throw BridgeException('Invalid base64 image data');
    }
    out.add(Attachment(
      name: 'image${out.length + 1}.${match.group(1)!.split('/').last}',
      mimeType: match.group(1)!,
      kind: AttachmentKind.image,
      size: bytes.length,
      bytes: bytes,
    ));
  }
  return out;
}

Map<String, dynamic> modelsResponse(List<SharedModel> models) => {
      'object': 'list',
      'data': [
        for (final m in models)
          {
            'id': m.id,
            'object': 'model',
            'created': 0,
            'owned_by': m.kind == ProviderKind.local ? 'this-device' : m.kind.vendor.toLowerCase(),
            if (m.displayName != null) 'name': m.displayName,
          },
      ],
    };

/// Builds OpenAI-style stream chunks and the final response.
class CompletionWriter {
  CompletionWriter(this.model)
      : id = 'chatcmpl-${DateTime.now().microsecondsSinceEpoch}',
        created = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final String model;
  final String id;
  final int created;
  final StringBuffer text = StringBuffer();
  final StringBuffer reasoning = StringBuffer();
  final UsageStats usage = UsageStats();
  final List<ToolCall> toolCalls = [];
  List<Map<String, dynamic>>? providerBlocks;
  ProviderKind? provider;
  String finishReason = 'stop';
  bool _sentRole = false;

  Map<String, dynamic> _chunk(Map<String, dynamic> delta, {String? finish}) => {
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': model,
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': finish},
        ],
      };

  /// Records [d] and returns the chunk to stream, or null if nothing to send.
  Map<String, dynamic>? add(ChatDelta d) {
    if (d.usage != null) usage.merge(d.usage!);
    if (d.notice != null && d.notice!.contains('length')) finishReason = 'length';
    if (d.providerBlocks != null) providerBlocks = d.providerBlocks;
    if (d.toolCalls.isNotEmpty) {
      final start = toolCalls.length;
      toolCalls.addAll(d.toolCalls);
      finishReason = 'tool_calls';
      final delta = <String, dynamic>{
        if (!_sentRole) 'role': 'assistant',
        'tool_calls': [
          for (final (i, c) in d.toolCalls.indexed)
            {
              'index': start + i,
              'id': c.id,
              'type': 'function',
              'function': {'name': c.name, 'arguments': jsonEncode(c.arguments)},
            },
        ],
      };
      _sentRole = true;
      return _chunk(delta);
    }
    if (d.text.isEmpty && d.reasoning.isEmpty) return null;
    text.write(d.text);
    reasoning.write(d.reasoning);
    final delta = <String, dynamic>{
      if (!_sentRole) 'role': 'assistant',
      if (d.text.isNotEmpty) 'content': d.text,
      if (d.reasoning.isNotEmpty) 'reasoning_content': d.reasoning,
    };
    _sentRole = true;
    return _chunk(delta);
  }

  /// Chatbot clients replay these blocks with the next request (Claude needs
  /// its signed thinking blocks back during a tool loop). Other OpenAI
  /// clients ignore the unknown fields.
  Map<String, dynamic> finalChunk() => _chunk({
        if (providerBlocks != null) ...{
          'x_provider': provider?.name,
          'x_provider_blocks': providerBlocks,
        },
      }, finish: finishReason);

  Map<String, dynamic>? usageChunk() => usage.inputTokens == null && usage.outputTokens == null
      ? null
      : {
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': model,
          'choices': const [],
          'usage': _usageJson(),
        };

  Map<String, dynamic> _usageJson() => {
        'prompt_tokens': usage.inputTokens ?? 0,
        'completion_tokens': usage.outputTokens ?? 0,
        'total_tokens': (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0),
      };

  Map<String, dynamic> completion() => {
        'id': id,
        'object': 'chat.completion',
        'created': created,
        'model': model,
        'choices': [
          {
            'index': 0,
            'message': {
              'role': 'assistant',
              'content': text.isEmpty && toolCalls.isNotEmpty ? null : text.toString(),
              if (reasoning.isNotEmpty) 'reasoning_content': reasoning.toString(),
              if (toolCalls.isNotEmpty)
                'tool_calls': [
                  for (final c in toolCalls)
                    {
                      'id': c.id,
                      'type': 'function',
                      'function': {'name': c.name, 'arguments': jsonEncode(c.arguments)},
                    },
                ],
              if (providerBlocks != null) ...{
                'x_provider': provider?.name,
                'x_provider_blocks': providerBlocks,
              },
            },
            'finish_reason': finishReason,
          },
        ],
        'usage': _usageJson(),
      };
}

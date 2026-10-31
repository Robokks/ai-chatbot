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
  });

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
  for (final m in raw) {
    if (m is! Map) throw BridgeException('Each message must be an object');
    final role = m['role'];
    final content = m['content'];
    switch (role) {
      case 'system' || 'developer':
        final t = _text(content);
        if (t.isNotEmpty) system.add(t);
      case 'assistant':
        messages.add(Message(role: Role.assistant, text: _text(content)));
      case 'user':
        messages.add(Message(
          role: Role.user,
          text: _text(content),
          attachments: _images(content),
        ));
      case 'tool':
        // Tool results from the client's own agent loop: pass as user context.
        final t = _text(content);
        if (t.isNotEmpty) messages.add(Message(role: Role.user, text: 'Tool result:\n$t'));
      default:
        throw BridgeException('Unsupported message role "$role"');
    }
  }
  if (!messages.any((m) => m.role == Role.user)) {
    throw BridgeException('At least one user message is required');
  }
  final streamOptions = body['stream_options'];
  return BridgedRequest(
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

  Map<String, dynamic> finalChunk() => _chunk(const {}, finish: finishReason);

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
              'content': text.toString(),
              if (reasoning.isNotEmpty) 'reasoning_content': reasoning.toString(),
            },
            'finish_reason': finishReason,
          },
        ],
        'usage': _usageJson(),
      };
}

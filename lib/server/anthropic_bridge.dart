import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../data/models.dart';
import 'openai_bridge.dart';

/// Normalize Messages API input using the same bounded/authenticated host pipeline.
BridgedRequest parseAnthropicRequest(Map<String, dynamic> body) {
  if (body['max_tokens'] is! int || (body['max_tokens'] as int) <= 0) {
    throw BridgeException('max_tokens must be a positive whole number');
  }
  final raw = body['messages'];
  if (raw is! List) throw BridgeException('messages must be a list');
  final messages = <Map<String, dynamic>>[];
  final system = body['system'];
  if (system is String) { messages.add({'role': 'system', 'content': system}); }
  else if (system is List) {
    messages.add({'role': 'system', 'content': system.whereType<Map>().where((b) => b['type'] == 'text').map((b) => b['text']).join('\n\n')});
  } else if (system != null) { throw BridgeException('Unsupported system prompt'); }
  for (final value in raw) {
    if (value is! Map || !['user', 'assistant'].contains(value['role'])) throw BridgeException('Invalid Messages API role');
    final role = value['role'] as String;
    final content = value['content'];
    if (content is String) { messages.add({'role': role, 'content': content}); continue; }
    if (content is! List) throw BridgeException('Message content must be text or blocks');
    final parts = <Map<String, dynamic>>[];
    final calls = <Map<String, dynamic>>[];
    for (final block in content) {
      if (block is! Map) throw BridgeException('Invalid content block');
      switch (block['type']) {
        case 'text': parts.add({'type': 'text', 'text': block['text']});
        case 'image':
          final source = block['source'];
          if (source is! Map || source['type'] != 'base64' || source['data'] is! String || source['media_type'] is! String) {
            throw BridgeException('Images must contain base64 data');
          }
          parts.add({'type': 'image_url', 'image_url': {'url': 'data:${source['media_type']};base64,${source['data']}'}});
        case 'document':
          final source = block['source'];
          if (source is! Map) throw BridgeException('Invalid document');
          if (source['type'] == 'text') { parts.add({'type': 'text', 'text': source['data']}); }
          else if (source['type'] == 'base64' && source['media_type'] == 'application/pdf') {
            parts.add({'type': 'file', 'file': {'filename': 'document.pdf', 'file_data': 'data:application/pdf;base64,${source['data']}'}});
          } else { throw BridgeException('Only text and base64 PDF documents are supported'); }
        case 'tool_use':
          if (role != 'assistant' || block['id'] is! String || block['name'] is! String || block['input'] is! Map) {
            throw BridgeException('Invalid tool_use block');
          }
          calls.add({'id': block['id'], 'type': 'function', 'function': {'name': block['name'], 'arguments': jsonEncode(block['input'])}});
        case 'tool_result':
          if (role != 'user' || block['tool_use_id'] is! String) throw BridgeException('Invalid tool_result block');
          final result = block['content'];
          final text = result is String ? result : result is List
              ? result.whereType<Map>().where((b) => b['type'] == 'text').map((b) => b['text']).join('\n') : '';
          messages.add({'role': 'tool', 'tool_call_id': block['tool_use_id'], 'content': '${block['is_error'] == true ? 'Tool error: ' : ''}$text'});
          if (result is List) {
            for (final image in result.whereType<Map>().where((b) => b['type'] == 'image')) {
              final source = image['source'];
              if (source is! Map || source['type'] != 'base64') throw BridgeException('Tool images must use base64 data');
              parts.add({'type': 'image_url', 'image_url': {'url': 'data:${source['media_type']};base64,${source['data']}'}});
            }
          }
        case 'thinking' || 'redacted_thinking':
          if (role != 'assistant') throw BridgeException('Thinking blocks belong to assistant messages');
        default: throw BridgeException('Unsupported Messages API content block');
      }
    }
    if (parts.isNotEmpty || calls.isNotEmpty) {
      messages.add({'role': role, 'content': parts, if (calls.isNotEmpty) 'tool_calls': calls,
        if (role == 'assistant') 'x_provider': 'anthropic',
        if (role == 'assistant') 'x_provider_blocks': content,
      });
    }
  }
  final tools = body['tools'];
  if (tools != null && tools is! List) throw BridgeException('tools must be a list');
  if (tools is List && tools.any((t) => t is! Map || t['name'] is! String || t['input_schema'] is! Map)) {
    throw BridgeException('Each tool needs a name and an input_schema object');
  }
  return parseChatRequest({'model': body['model'], 'stream': body['stream'] == true, 'messages': messages,
    'tools': [for (final tool in tools as List? ?? const [])
      if (tool is Map) {'type': 'function', 'function': {'name': tool['name'], 'description': tool['description'] ?? '',
        'parameters': tool['input_schema'] ?? {'type': 'object', 'properties': {}}}}],
  });
}

List<Map<String, dynamic>> anthropicContent(String text, List<ToolCall> calls,
    {List<Map<String, dynamic>>? nativeBlocks}) => nativeBlocks ?? [
  if (text.isNotEmpty) {'type': 'text', 'text': text},
  for (final call in calls) {'type': 'tool_use', 'id': call.id, 'name': call.name, 'input': call.arguments},
];

Map<String, dynamic> anthropicMessage({required String id, required String model,
    required List<Map<String, dynamic>> content, required UsageStats usage}) => {
  'id': id, 'type': 'message', 'role': 'assistant', 'model': model, 'content': content,
  'stop_reason': content.any((b) => b['type'] == 'tool_use') ? 'tool_use' : 'end_turn', 'stop_sequence': null,
  'usage': {'input_tokens': usage.inputTokens ?? 0, 'output_tokens': usage.outputTokens ?? 0},
};

/// Preserve signed native thinking and complete tool inputs in a portable SSE form.
Iterable<({String event, Map<String, dynamic> data})> anthropicBlockEvents(Map<String, dynamic> block, int index) sync* {
  final type = block['type'];
  final start = Map<String, dynamic>.from(block);
  if (type == 'text') start['text'] = '';
  if (type == 'thinking') { start['thinking'] = ''; start['signature'] = ''; }
  if (type == 'tool_use') start['input'] = <String, dynamic>{};
  yield (event: 'content_block_start', data: {'type': 'content_block_start', 'index': index, 'content_block': start});
  if (type == 'text') { yield (event: 'content_block_delta', data: {'type': 'content_block_delta', 'index': index,
    'delta': {'type': 'text_delta', 'text': block['text'] ?? ''}}); }
  if (type == 'thinking') {
    yield (event: 'content_block_delta', data: {'type': 'content_block_delta', 'index': index,
      'delta': {'type': 'thinking_delta', 'thinking': block['thinking'] ?? ''}});
    yield (event: 'content_block_delta', data: {'type': 'content_block_delta', 'index': index,
      'delta': {'type': 'signature_delta', 'signature': block['signature'] ?? ''}});
  }
  if (type == 'tool_use') { yield (event: 'content_block_delta', data: {'type': 'content_block_delta', 'index': index,
    'delta': {'type': 'input_json_delta', 'partial_json': jsonEncode(block['input'] ?? {})}}); }
  yield (event: 'content_block_stop', data: {'type': 'content_block_stop', 'index': index});
}

/// Match protocol replay state to the exact PC, model and assistant turn.
String messageReplayKey(String device, String model, Message message) {
  Object? sorted(Object? value) {
    if (value is List) return value.map(sorted).toList();
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(value[key])};
    }
    return value;
  }
  return sha256.convert(utf8.encode(jsonEncode(sorted({'device': device, 'model': model,
    'text': message.text, 'calls': message.toolCalls.map((c) => c.toJson()).toList()})))).toString();
}

Map<String, dynamic> anthropicError(int status, String message) => {
  'type': 'error', 'error': {'type': switch (status) {
    401 => 'authentication_error', 403 => 'permission_error', 404 => 'not_found_error',
    429 => 'rate_limit_error', >= 500 => 'api_error', _ => 'invalid_request_error',
  }, 'message': message},
};

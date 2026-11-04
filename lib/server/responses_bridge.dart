import 'dart:convert';

import '../data/models.dart';
import 'openai_bridge.dart';

/// Stateless Responses translation. Clients must send full history (store:false).
class ResponsesRequest {
  ResponsesRequest(this.request, this.customTools, this.maxOutputTokens);
  final BridgedRequest request;
  final Set<String> customTools;
  final int? maxOutputTokens;
}

ResponsesRequest parseResponsesRequest(Map<String, dynamic> body) {
  for (final key in ['previous_response_id', 'conversation', 'background']) {
    if (body[key] != null && body[key] != false) {
      throw BridgeException(
        '$key is unsupported; send complete history with store:false',
      );
    }
  }
  if (body['store'] == true) {
    throw BridgeException('Response storage is unsupported; use store:false');
  }
  if (body['tool_choice'] != null && body['tool_choice'] != 'auto') {
    throw BridgeException('Only automatic tool choice is supported');
  }
  if (body['text'] is Map &&
      (body['text'] as Map)['format'] is Map &&
      ((body['text'] as Map)['format'] as Map)['type'] != 'text') {
    throw BridgeException('Structured output formats are unsupported');
  }
  final reasoning = body['reasoning'];
  if (reasoning != null &&
      (reasoning is! Map ||
          (reasoning['effort'] != null && reasoning['effort'] != 'none') ||
          (reasoning['summary'] != null && reasoning['summary'] != 'none'))) {
    throw BridgeException(
      'Reasoning controls are unsupported; configure reasoning effort and summary as none',
    );
  }
  for (final key in ['temperature', 'top_p', 'truncation', 'service_tier']) {
    if (body[key] != null &&
        !(key == 'truncation' && body[key] == 'disabled') &&
        !(key == 'service_tier' && body[key] == 'auto')) {
      throw BridgeException(
        '$key is unsupported by this compatibility endpoint',
      );
    }
  }
  final limit = body['max_output_tokens'];
  if (limit != null && (limit is! int || limit <= 0)) {
    throw BridgeException('max_output_tokens must be positive');
  }
  final custom = <String>{};
  final tools = <Map<String, dynamic>>[];
  final rawTools = body['tools'] ?? const [];
  if (rawTools is! List) throw BridgeException('tools must be a list');
  for (final tool in rawTools) {
    if (tool is! Map || tool['name'] is! String) {
      throw BridgeException('Invalid tool definition');
    }
    final type = tool['type'];
    if (type != 'function' && type != 'custom') {
      throw BridgeException('Unsupported server tool: $type');
    }
    if (type == 'custom') custom.add(tool['name'] as String);
    tools.add({
      'type': 'function',
      'function': {
        'name': tool['name'],
        'description':
            '${tool['description'] ?? ''}${type == 'custom' ? '\nReturn the exact raw tool input in the input string. Format: ${jsonEncode(tool['format'])}' : ''}',
        'parameters': type == 'custom'
            ? {
                'type': 'object',
                'properties': {
                  'input': {'type': 'string'},
                },
                'required': ['input'],
                'additionalProperties': false,
              }
            : tool['parameters'] ?? {'type': 'object', 'properties': {}},
      },
    });
  }
  final messages = <Map<String, dynamic>>[];
  if (body['instructions'] != null) {
    messages.add({'role': 'system', 'content': body['instructions']});
  }
  final input = body['input'];
  final items = input is String
      ? [
          {'role': 'user', 'content': input},
        ]
      : input;
  if (items is! List) throw BridgeException('input must be text or a list');
  for (final item in items) {
    if (item is! Map) throw BridgeException('Invalid input item');
    switch (item['type'] ?? 'message') {
      case 'message':
        final content = item['content'];
        final parts = <Map<String, dynamic>>[];
        if (content is List) {
          for (final part in content) {
            if (part is! Map) throw BridgeException('Invalid message content');
            switch (part['type']) {
              case 'input_text' || 'output_text':
                parts.add({'type': 'text', 'text': part['text']});
              case 'input_image':
                parts.add({
                  'type': 'image_url',
                  'image_url': {'url': part['image_url']},
                });
              case 'input_file':
                parts.add({
                  'type': 'file',
                  'file': {
                    'filename': part['filename'] ?? 'document.pdf',
                    'file_data': part['file_data'],
                  },
                });
              default:
                throw BridgeException(
                  'Unsupported input content: ${part['type']}',
                );
            }
          }
        } else if (content is! String) {
          throw BridgeException('Invalid message content');
        }
        messages.add({
          'role': item['role'],
          'content': content is String ? content : parts,
        });
      case 'function_call' || 'custom_tool_call':
        final isCustom = item['type'] == 'custom_tool_call';
        messages.add({
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': item['call_id'],
              'type': 'function',
              'function': {
                'name': item['name'],
                'arguments': isCustom
                    ? jsonEncode({'input': item['input']})
                    : item['arguments'],
              },
            },
          ],
        });
      case 'function_call_output' || 'custom_tool_call_output':
        final output = item['output'];
        if (output is! String && output is! List) {
          throw BridgeException('Invalid tool output');
        }
        if (output is List &&
            output.any((p) => p is! Map || p['type'] != 'input_text')) {
          throw BridgeException(
            'Only text tool outputs are currently supported',
          );
        }
        messages.add({
          'role': 'tool',
          'tool_call_id': item['call_id'],
          'content': output is String
              ? output
              : (output as List).map((p) => p['text']).join('\n'),
        });
      case 'reasoning':
        // Foreign encrypted reasoning cannot be interpreted safely by another provider.
        if (item['encrypted_content'] != null) {
          throw BridgeException('Encrypted Responses reasoning is unsupported');
        }
      default:
        throw BridgeException('Unsupported input item: ${item['type']}');
    }
  }
  // Responses emits one assistant turn as a message followed by separate call
  // items. Reassemble that turn before matching Main's signed replay cache.
  final turns = <Map<String, dynamic>>[];
  for (final message in messages) {
    if (message['role'] == 'assistant') {
      final content = message['content'];
      final text = content is String
          ? content
          : (content as List)
                .whereType<Map>()
                .map((part) => part['text'] as String? ?? '')
                .join();
      if (turns.isNotEmpty && turns.last['role'] == 'assistant') {
        final previous = turns.last;
        previous['content'] = '${previous['content']}$text';
        previous['tool_calls'] = [
          ...previous['tool_calls'] as List? ?? const [],
          ...message['tool_calls'] as List? ?? const [],
        ];
        continue;
      }
      message['content'] = text;
    }
    turns.add(message);
  }
  return ResponsesRequest(
    parseChatRequest({
      'model': body['model'],
      'stream': body['stream'] == true,
      'messages': turns,
      'tools': tools,
    }),
    custom,
    limit as int?,
  );
}

List<Map<String, dynamic>> responsesOutput(
  String text,
  List<ToolCall> calls,
  Set<String> custom,
) => [
  if (text.isNotEmpty)
    {
      'id': 'msg_final',
      'type': 'message',
      'role': 'assistant',
      'status': 'completed',
      'content': [
        {'type': 'output_text', 'text': text, 'annotations': []},
      ],
    },
  for (final call in calls)
    {
      'id': 'item_${call.id}',
      'type': custom.contains(call.name) ? 'custom_tool_call' : 'function_call',
      'call_id': call.id,
      'name': call.name,
      'status': 'completed',
      if (custom.contains(call.name))
        'input':
            call.arguments['input'] ??
            call.arguments['_raw'] ??
            jsonEncode(call.arguments),
      if (!custom.contains(call.name)) 'arguments': jsonEncode(call.arguments),
    },
];

Map<String, dynamic> responsesMessage({
  required String id,
  required String model,
  required List<Map<String, dynamic>> output,
  required UsageStats usage,
}) => {
  'id': id,
  'object': 'response',
  'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  'status': 'completed',
  'error': null,
  'incomplete_details': null,
  'model': model,
  'output': output,
  'usage': {
    'input_tokens': usage.inputTokens ?? 0,
    'output_tokens': usage.outputTokens ?? 0,
    'total_tokens': (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0),
  },
};

/// Complete items are essential: Codex dispatches function/custom calls on done.
Iterable<({String event, Map<String, dynamic> data})> responsesCompletedEvents(
  Map<String, dynamic> response,
) sync* {
  final output = response['output'] as List;
  for (final (index, item) in output.indexed) {
    yield (
      event: 'response.output_item.done',
      data: {
        'type': 'response.output_item.done',
        'output_index': index,
        'item': item,
      },
    );
  }
  yield (
    event: 'response.completed',
    data: {'type': 'response.completed', 'response': response},
  );
}

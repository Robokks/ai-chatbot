import 'dart:convert';

import '../data/models.dart';
import 'openai_bridge.dart';

/// Builds the UTCP v1 manual that describes this host's HTTP tools.
/// See https://www.utcp.io — clients call the endpoints directly.
Map<String, dynamic> utcpManual({
  required String origin,
  required String hostName,
  required List<SharedModel> models,
}) {
  final auth = {
    'auth_type': 'api_key',
    'api_key': r'Bearer ${CHATBOT_HOST_KEY}',
    'var_name': 'Authorization',
    'location': 'header',
  };
  return {
    'manual_version': '1.0.0',
    'utcp_version': '1.0.1',
    'info': {
      'title': 'Chatbot host: $hostName',
      'version': '1.0.0',
      'description': 'AI models shared by $hostName on the local network.',
    },
    'tools': [
      {
        'name': 'list_models',
        'description': 'List the AI models this host shares.',
        'inputs': {'type': 'object', 'properties': {}},
        'outputs': {'type': 'object', 'description': 'OpenAI-style model list'},
        'tags': ['ai', 'models'],
        'tool_call_template': {
          'call_template_type': 'http',
          'url': '$origin/v1/models',
          'http_method': 'GET',
          'auth': auth,
        },
      },
      {
        'name': 'chat',
        'description': 'Ask an AI model on $hostName and get its answer as text.',
        'inputs': {
          'type': 'object',
          'properties': {
            'request': {
              'type': 'object',
              'properties': {
                'prompt': {'type': 'string', 'description': 'The question or instruction'},
                'model': {
                  'type': 'string',
                  'description': 'Model id; defaults to the first shared model',
                  if (models.isNotEmpty) 'enum': [for (final m in models) m.id],
                },
                'system': {'type': 'string', 'description': 'Optional system prompt'},
              },
              'required': ['prompt'],
            },
          },
          'required': ['request'],
        },
        'outputs': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
            'model': {'type': 'string'},
          },
        },
        'tags': ['ai', 'chat', 'llm'],
        'tool_call_template': {
          'call_template_type': 'http',
          'url': '$origin/tools/chat',
          'http_method': 'POST',
          'content_type': 'application/json',
          'body_field': 'request',
          'auth': auth,
        },
      },
    ],
  };
}

/// A2A 1.0 Agent Card for this host.
Map<String, dynamic> a2aAgentCard({
  required String origin,
  required String hostName,
  required List<SharedModel> models,
}) =>
    {
      'name': 'Chatbot on $hostName',
      'description': 'Answers questions using AI models shared by $hostName. '
          'Pick a model with metadata.model; available: '
          '${models.map((m) => m.id).join(', ')}.',
      'supportedInterfaces': [
        {'url': '$origin/a2a', 'protocolBinding': 'JSONRPC', 'protocolVersion': '1.0'},
      ],
      'version': '1.0.0',
      'capabilities': {'streaming': true, 'pushNotifications': false},
      'defaultInputModes': ['text/plain'],
      'defaultOutputModes': ['text/plain'],
      'skills': [
        for (final m in models)
          {
            'id': m.id,
            'name': m.displayName ?? m.model,
            'description': m.kind == ProviderKind.local
                ? 'Chat with ${m.displayName ?? m.model}, running on $hostName.'
                : 'Chat with ${m.model} via $hostName.',
            'tags': ['chat', m.kind.name],
          },
      ],
      'securitySchemes': {
        'bearer': {
          'httpAuthSecurityScheme': {'scheme': 'Bearer', 'description': 'Chatbot host access key'},
        },
      },
      'securityRequirements': [
        {
          'schemes': {
            'bearer': {'list': <String>[]},
          },
        },
      ],
    };

/// A parsed A2A SendMessage request.
class A2aRequest {
  const A2aRequest(this.text, this.contextId, this.model);
  final String text;
  final String contextId;
  final String? model;
}

class A2aError implements Exception {
  A2aError(this.code, this.message);
  final int code;
  final String message;
}

A2aRequest parseA2aSend(Object? params, String Function() newId) {
  if (params is! Map) throw A2aError(-32602, 'Invalid parameters');
  final message = params['message'];
  if (message is! Map || message['parts'] is! List) {
    throw A2aError(-32602, 'Invalid parameters: message.parts is required');
  }
  final text = [
    for (final p in message['parts'] as List)
      if (p is Map && p['text'] is String) p['text'] as String,
  ].join('\n');
  if (text.trim().isEmpty) throw A2aError(-32602, 'Invalid parameters: a text part is required');
  final meta = {...?(params['metadata'] as Map?), ...?(message['metadata'] as Map?)};
  return A2aRequest(
    text,
    (message['contextId'] as String?) ?? newId(),
    meta['model'] as String?,
  );
}

Map<String, dynamic> a2aMessage(String text, String contextId, String id) => {
      'messageId': id,
      'contextId': contextId,
      'role': 'ROLE_AGENT',
      'parts': [
        {'text': text},
      ],
    };

String jsonRpcResult(Object? id, Object result) =>
    jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});

String jsonRpcError(Object? id, int code, String message) => jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });

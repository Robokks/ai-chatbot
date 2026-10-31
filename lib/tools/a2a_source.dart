import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../data/models.dart';
import 'tool_source.dart';

/// An A2A agent used as a tool: the AI can ask it questions.
/// Speaks A2A 1.0 (SendMessage) and falls back to 0.3 (message/send).
class A2aToolSource extends ToolSource {
  A2aToolSource(super.config, super.secret, {http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  Uri? _endpoint;
  bool _legacy = false;
  List<String> _skills = const [];

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'a2a-version': _legacy ? '0.3' : '1.0',
        if (secret != null && secret!.isNotEmpty) 'authorization': 'Bearer $secret',
      };

  Uri get _cardUrl {
    final u = Uri.parse(config.url.trim());
    return u.path.endsWith('.json') ? u : u.replace(path: '/.well-known/agent-card.json');
  }

  @override
  Future<List<SourceTool>> discover() async {
    final res = await _client.get(_cardUrl, headers: _headers).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw HttpException('Agent card not found (status ${res.statusCode})');
    final card = jsonDecode(res.body) as Map<String, dynamic>;
    final interfaces = (card['supportedInterfaces'] as List? ?? const []).cast<Map>();
    final jsonRpc = interfaces.where((i) => i['protocolBinding'] == 'JSONRPC').toList();
    if (jsonRpc.isNotEmpty) {
      _endpoint = Uri.parse(jsonRpc.first['url'] as String);
      _legacy = !('${jsonRpc.first['protocolVersion']}'.startsWith('1'));
    } else if (card['url'] is String) {
      _endpoint = Uri.parse(card['url'] as String); // A2A 0.3 card
      _legacy = true;
    } else {
      throw const FormatException('The agent has no JSON-RPC endpoint');
    }
    final skills = (card['skills'] as List? ?? const []).cast<Map>();
    _skills = [for (final s in skills) '${s['id']}'];
    final agent = card['name'] as String? ?? config.name;
    return [
      SourceTool(
        name: 'ask',
        description: 'Ask the AI agent "$agent". ${card['description'] ?? ''}'
            '${skills.isEmpty ? '' : ' Skills: ${skills.map((s) => '${s['id']} (${s['name']})').join(', ')}.'}',
        inputSchema: {
          'type': 'object',
          'properties': {
            'message': {'type': 'string', 'description': 'What to ask or tell the agent'},
            if (_skills.isNotEmpty)
              'skill': {
                'type': 'string',
                'enum': _skills,
                'description': 'Optional skill to use',
              },
          },
          'required': ['message'],
        },
      ),
    ];
  }

  @override
  Future<ToolOutput> call(String tool, Map<String, dynamic> arguments) async {
    if (_endpoint == null) await discover();
    final text = '${arguments['message'] ?? ''}';
    final skill = arguments['skill'] as String?;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final message = _legacy
        ? {
            'kind': 'message',
            'role': 'user',
            'messageId': newId(),
            'parts': [
              {'kind': 'text', 'text': text},
            ],
          }
        : {
            'role': 'ROLE_USER',
            'messageId': newId(),
            'parts': [
              {'text': text},
            ],
          };
    final result = await _rpc(id, _legacy ? 'message/send' : 'SendMessage', {
      'message': message,
      if (skill != null) 'metadata': {'skill': skill, 'model': skill},
    });
    return ToolOutput(clip(await _textOf(result)));
  }

  Future<Map<String, dynamic>> _rpc(String id, String method, Map<String, dynamic> params) async {
    final res = await _client
        .post(_endpoint!,
            headers: _headers,
            body: jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}))
        .timeout(const Duration(minutes: 3));
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw HttpException('The agent refused the access key (status ${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['error'] != null) {
      throw HttpException('Agent error: ${(body['error'] as Map)['message']}');
    }
    return Map<String, dynamic>.from(body['result'] as Map);
  }

  /// Text of a Message or Task result; polls a still-running task briefly.
  Future<String> _textOf(Map<String, dynamic> result) async {
    var r = result;
    for (var i = 0; i < 60; i++) {
      final msg = r['message'] ?? (r['kind'] == 'message' ? r : null);
      if (msg is Map) return _partsText(msg['parts']);
      final task = r['task'] ?? (r['kind'] == 'task' ? r : null);
      if (task is! Map) return jsonEncode(r);
      final status = task['status'] as Map? ?? const {};
      final state = '${status['state']}'.toLowerCase();
      if (state.contains('working') || state.contains('submitted')) {
        await Future<void>.delayed(const Duration(seconds: 1));
        r = await _rpc('poll$i', _legacy ? 'tasks/get' : 'GetTask', {'id': task['id']});
        if (!r.containsKey('task') && r['kind'] != 'task') r = {'task': r};
        continue;
      }
      final artifacts = [
        for (final a in task['artifacts'] as List? ?? const []) _partsText((a as Map)['parts']),
      ].where((t) => t.isNotEmpty);
      if (artifacts.isNotEmpty) return artifacts.join('\n\n');
      final m = status['message'];
      return m is Map ? _partsText(m['parts']) : 'The agent finished ($state) without a reply.';
    }
    return 'The agent is still working; try again later.';
  }

  static String _partsText(Object? parts) => [
        for (final p in parts as List? ?? const [])
          if (p is Map && p['text'] is String) p['text'] as String,
      ].join('\n');
}

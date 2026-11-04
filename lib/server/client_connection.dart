import 'dart:convert';
import 'package:http/http.dart' as http;

import '../data/llm/llm_provider.dart';

/// Uses only the paired Main URL and key; no credentials appear in status text.
class ClientConnection {
  ClientConnection(String base, this.key, {http.Client? client})
      : base = Uri.parse(base), _client = client ?? http.Client();
  final Uri base;
  final String key;
  final http.Client _client;
  Future<Map<String, dynamic>> access({bool request = false}) async {
    final uri = base.replace(path: request ? '/access/request' : '/access', query: '', fragment: '');
    final headers = {'authorization': 'Bearer $key', 'content-type': 'application/json'};
    final response = await (request ? _client.post(uri, headers: headers, body: '{}')
        : _client.get(uri, headers: headers)).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw LlmException('Main is unavailable or this PC key was revoked.', statusCode: response.statusCode);
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }
  void close() => _client.close();
}

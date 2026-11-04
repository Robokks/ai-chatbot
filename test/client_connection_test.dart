import 'dart:convert';
import 'package:ai_chatbot/server/client_connection.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('status and request-access use the paired host key and do not self-grant', () async {
    final calls = <http.Request>[];
    final connection = ClientConnection('http://main.example:8484/v1', 'test-key',
      client: MockClient((request) async {
        calls.add(request);
        expect(request.headers['authorization'], 'Bearer test-key');
        if (request.method == 'POST') {
          expect(jsonDecode(request.body), isEmpty);
          return http.Response('{"message":"Waiting"}', 202);
        }
        return http.Response('{"access":{"approved":false},"usage":{"requests":0}}', 200);
      }));
    expect((await connection.access())['access']['approved'], isFalse);
    await connection.access(request: true);
    expect(calls.map((r) => r.url.path), ['/access', '/access/request']);
    connection.close();
  });
  test('revoked credentials produce a useful connection error', () async {
    final connection = ClientConnection('http://main.example/v1', 'test-key',
      client: MockClient((_) async => http.Response('{}', 401)));
    await expectLater(connection.access(), throwsA(isA<LlmException>()));
    connection.close();
  });
}

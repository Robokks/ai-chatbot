import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';

class AccessBackend implements HostBackend {
  final requests = <ChatRequest>[];
  Completer<void>? hold;
  @override String get deviceName => 'Main';
  @override List<SharedModel> sharedModels() => const [
    SharedModel(ProviderKind.local, 'one'), SharedModel(ProviderKind.openai, 'two')];
  @override LlmProvider providerFor(ProviderKind kind) => AccessProvider(this, kind);
}
class AccessProvider extends LlmProvider {
  AccessProvider(this.backend, ProviderKind kind) : super(settings: ProviderSettings(kind: kind), apiKey: 'test');
  final AccessBackend backend;
  @override Stream<ChatDelta> streamChat(ChatRequest request) async* {
    backend.requests.add(request);
    if (backend.hold != null) await backend.hold!.future;
    yield const ChatDelta(text: 'Hello');
    yield ChatDelta(usage: UsageStats(inputTokens: 10, outputTokens: 5));
  }
  @override Future<List<String>> listModels() async => [];
}
void main() {
  late HostServer host;
  late AccessBackend backend;
  late PairedDevice alice, bob;
  late HttpClient http;
  final clients = <McpClient>[];
  Future<(int, Map)> call(String path, PairedDevice d, {Map? body}) async {
    final request = await http.openUrl(body == null ? 'GET' : 'POST',
        Uri.parse('http://127.0.0.1:${host.port}$path'));
    request.headers.set('authorization', 'Bearer ${d.key}');
    if (body != null) { request.headers.contentType = ContentType.json; request.write(jsonEncode(body)); }
    final response = await request.close();
    return (response.statusCode, jsonDecode(await utf8.decoder.bind(response).join()) as Map);
  }
  Map prompt(String model) => {'model': model, 'messages': [{'role': 'user', 'content': 'Hi'}]};
  Future<McpClient> connect(PairedDevice d) async {
    final client = McpClient(const Implementation(name: 'client', version: '1'));
    clients.add(client);
    await client.connect(StreamableHttpClientTransport(
      Uri.parse('http://127.0.0.1:${host.mcpPort}/mcp'),
      opts: StreamableHttpClientTransportOptions(requestInit: {'headers': {'Authorization': 'Bearer ${d.key}'}}),
    ));
    return client;
  }
  setUp(() async {
    backend = AccessBackend();
    http = HttpClient();
    host = HostServer(backend, loadDevices: () async => [], saveDevices: (_) async {}, approvalsRequired: () => true);
    await host.start(port: 0, address: InternetAddress.loopbackIPv4);
    alice = await host.createKey('Alice'); bob = await host.createKey('Bob');
  });
  tearDown(() async {
    backend.hold?.complete();
    for (final client in clients) { await client.close(); }
    clients.clear();
    http.close(force: true);
    await host.stop();
    host.dispose();
  });

  test('model and service allowlists, request limits, expiry, block and Stop all', () async {
    await host.updateAccess(alice, ClientAccess(models: {'openai/two'}, services: {'chat'}, requestsPerDay: 1));
    expect((await call('/v1/models', alice)).$2['data'].map((e) => e['id']), ['openai/two']);
    expect((await call('/v1/chat/completions', alice, body: prompt('local/one'))).$1, 403);
    expect((await call('/v1/chat/completions', alice, body: prompt('openai/two'))).$1, 200);
    expect((await call('/v1/chat/completions', alice, body: prompt('openai/two'))).$1, 429);
    alice.access.blocked = true;
    expect((await call('/v1/models', alice)).$1, 403);
    expect((await call('/access/request', alice, body: {})).$1, 202);
    expect(alice.accessRequested, isTrue);
    await host.updateAccess(alice, ClientAccess(expires: DateTime(2020)));
    expect((await call('/v1/models', alice)).$1, 403);
    host.stopAll = true;
    expect((await call('/v1/models', bob)).$1, 403);
    expect((await call('/access', bob)).$2['stopped'], isTrue);
  });

  test('client-reported tools do not grant permissions and unallowed tool schemas are rejected', () async {
    await host.updateAccess(alice, ClientAccess(tools: {}));
    expect((await call('/access/tools', alice, body: {'tools': {'local_git_run': 'Git on this PC'}})).$1, 200);
    expect(alice.clientTools, {'local_git_run': 'Git on this PC'});
    expect(alice.access.tools, isEmpty);
    final body = prompt('local/one')..['tools'] = [{'type': 'function',
      'function': {'name': 'local_git_run', 'description': 'Git', 'parameters': {'type': 'object'}}}];
    expect((await call('/v1/chat/completions', alice, body: body)).$1, 403);
    await host.updateAccess(alice, ClientAccess(tools: {'local_git_run'}));
    expect((await call('/v1/chat/completions', alice, body: body)).$1, 200);
    expect((await call('/access/tools', alice, body: {'tools': {'bad name': 'x'}})).$1, 400);
  });

  test('two simultaneous MCP clients get their own allowed models and default route', () async {
    await host.updateAccess(alice, ClientAccess(models: {'local/one'}));
    await host.updateAccess(bob, ClientAccess(models: {'openai/two'}));
    final connections = await Future.wait([connect(alice), connect(bob)]);
    final lists = await Future.wait([for (final c in connections) c.callTool(const CallToolRequest(name: 'list_models'))]);
    expect((lists[0].content.single as TextContent).text, contains('local/one'));
    expect((lists[0].content.single as TextContent).text, isNot(contains('openai/two')));
    expect((lists[1].content.single as TextContent).text, contains('openai/two'));
    final results = await Future.wait([for (final c in connections) c.callTool(const CallToolRequest(name: 'chat', arguments: {'prompt': 'Hi'}))]);
    expect(results.every((r) => r.isError != true), isTrue);
    expect(backend.requests.map((r) => r.model).toSet(), {'one', 'two'});
    final denied = await connections[0].callTool(const CallToolRequest(name: 'chat', arguments: {'model': 'openai/two', 'prompt': 'Hi'}));
    expect(denied.isError, isTrue);
    await host.revoke(alice);
    await expectLater(connections[0].callTool(const CallToolRequest(name: 'list_models')), throwsA(anything));
  });

  test('a legacy session id from another PC cannot be reused', () async {
    Future<(int, String?)> legacy(PairedDevice device, Map body, {String? session}) async {
      final request = await http.postUrl(Uri.parse('http://127.0.0.1:${host.mcpPort}/mcp'));
      request.headers.set('authorization', 'Bearer ${device.key}');
      request.headers.set('accept', 'application/json, text/event-stream');
      request.headers.set('mcp-protocol-version', '2025-03-26');
      if (session != null) request.headers.set('mcp-session-id', session);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final result = (response.statusCode, response.headers.value('mcp-session-id'));
      await response.drain<void>();
      return result;
    }
    final init = await legacy(alice, {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
      'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'legacy', 'version': '1'}}});
    expect(init.$1, 200);
    expect(init.$2, isNotNull);
    await legacy(alice, {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, session: init.$2);
    expect((await legacy(alice, {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}, session: init.$2)).$1, 200);
    expect((await legacy(bob, {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'}, session: init.$2)).$1, 404);
  });

  test('token cap reaches the provider and concurrent calls cannot overspend', () async {
    await host.updateAccess(alice, ClientAccess(tokensPerDay: 20000));
    backend.hold = Completer<void>();
    final first = call('/v1/chat/completions', alice, body: prompt('local/one'));
    for (var i = 0; i < 100 && backend.requests.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(backend.requests.single.maxOutputTokens, greaterThan(0));
    expect((await call('/v1/chat/completions', alice, body: prompt('local/one'))).$1, 429);
    backend.hold!.complete(); backend.hold = null;
    expect((await first).$1, 200);
    expect(alice.usage.tokens, 15);
  });

  test('Stop all interrupts a stalled provider and revokes an existing MCP connection', () async {
    final client = await connect(alice);
    backend.hold = Completer<void>();
    final first = call('/v1/chat/completions', alice, body: prompt('local/one'));
    for (var i = 0; i < 100 && backend.requests.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    host.stopAll = true;
    expect((await first.timeout(const Duration(seconds: 2))).$1, 502);
    await expectLater(client.callTool(const CallToolRequest(name: 'list_models')), throwsA(anything));
  });

  test('new lab pairings wait for approval and cannot grant themselves access', () async {
    final request = await http.postUrl(Uri.parse('http://127.0.0.1:${host.port}/pair'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'pin': host.pin, 'device': 'New PC'}));
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    final device = host.devices.last;
    expect(device.access.approved, isFalse);
    expect((await call('/v1/models', device)).$1, 403);
    expect((await call('/access/request', device, body: {'approved': true})).$1, 202);
    expect(device.access.approved, isFalse);
    await host.updateAccess(device, ClientAccess(models: {'local/one'}));
    expect((await call('/v1/models', device)).$1, 200);
  });
}

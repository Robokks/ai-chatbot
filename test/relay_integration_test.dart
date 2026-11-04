import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/relay_forwarder.dart';
import 'package:ai_chatbot/server/relay_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'client_access_integration_test.dart' show AccessBackend;

void main() {
  late HostServer main, outer, inner;
  late AccessBackend backend;
  late PairedDevice a, b, leaf;
  late HttpClient http;
  final connected = <McpClient>[];
  Future<(int, Map)> call(HostServer host, String path, {String? key, Map? body}) async {
    final request = await http.openUrl(body == null ? 'GET' : 'POST', Uri.parse('http://127.0.0.1:${host.port}$path'));
    if (key != null) request.headers.set('authorization', 'Bearer $key');
    if (body != null) { request.headers.contentType = ContentType.json; request.write(jsonEncode(body)); }
    final response = await request.close();
    return (response.statusCode, jsonDecode(await utf8.decoder.bind(response).join()) as Map);
  }
  ClientAccess relayAccess() => ClientAccess(services: {'relay', 'mcp', 'chat', 'a2a'});
  HostServer server(AccessBackend backend) => HostServer(backend, loadDevices: () async => [], saveDevices: (_) async {});
  Future<PairedDevice> pair(HostServer host, String name) async {
    final result = await call(host, '/pair', body: {'pin': host.pin, 'device': name});
    expect(result.$1, 200, reason: '${result.$2}');
    return main.devices.firstWhere((d) => d.key == result.$2['key']);
  }
  setUp(() async {
    http = HttpClient(); backend = AccessBackend();
    main = server(backend); outer = server(AccessBackend()); inner = server(AccessBackend());
    await main.start(port: 0, address: InternetAddress.loopbackIPv4);
    a = await main.createKey('Relay A'); await main.updateAccess(a, relayAccess());
    outer.relay = RelayForwarder(upstream: Uri.parse('http://127.0.0.1:${main.port}'),
      identity: RelayIdentity(a.id, a.key, a.via), mcpPort: () => outer.mcpPort);
    await outer.start(port: 0, address: InternetAddress.loopbackIPv4);
    b = await pair(outer, 'Relay B');
    expect(b.access.approved, isFalse);
    expect(b.via, [a.id]);
    await main.updateAccess(b, relayAccess());
    inner.relay = RelayForwarder(upstream: Uri.parse('http://127.0.0.1:${outer.port}'),
      identity: RelayIdentity(b.id, b.key, b.via), mcpPort: () => inner.mcpPort);
    await inner.start(port: 0, address: InternetAddress.loopbackIPv4);
    leaf = await pair(inner, 'Far PC');
    await main.updateAccess(leaf, ClientAccess(models: {'openai/two'}, services: {'chat', 'mcp', 'a2a'}, tokensPerDay: 20000));
  });
  tearDown(() async {
    backend.hold?.complete();
    for (final client in connected) { await client.close(); }
    connected.clear(); http.close(force: true);
    await inner.stop(); await outer.stop(); await main.stop();
  });
  Map prompt() => {'model': 'openai/two', 'messages': [{'role': 'user', 'content': 'Hello'}]};

  test('a PC behind two relays is visible on Main and uses only its allowed models', () async {
    expect(leaf.via, [a.id, b.id]);
    final list = await call(inner, '/v1/models', key: leaf.key);
    expect(list.$1, 200, reason: '${list.$2}');
    expect(list.$2['data'].map((m) => m['id']), ['openai/two']);
    final answer = await call(inner, '/v1/chat/completions', key: leaf.key, body: prompt());
    expect(answer.$1, 200, reason: '${answer.$2}');
    expect(answer.$2['choices'][0]['message']['content'], 'Hello');
    expect(main.log.first.device, 'Far PC');
    expect([leaf.usage.tokens, a.usage.tokens, b.usage.tokens], [15, 15, 15]);
    final metadata = await call(inner, '/access', key: leaf.key);
    expect(metadata.$2['mcpPort'], inner.mcpPort);
    expect(metadata.$2['via'].map((v) => v['name']), ['Relay A', 'Relay B']);
    expect((await call(main, '/v1/models', key: leaf.key)).$1, 401, reason: 'a relayed key cannot skip its approved path');
    expect((await call(outer, '/v1/models', key: leaf.key)).$1, 403, reason: 'the far PC cannot skip Relay B');
  });

  test('MCP sessions and calls work through both relays with the leaf identity', () async {
    final client = McpClient(const Implementation(name: 'far-pc', version: '1'));
    connected.add(client);
    await client.connect(StreamableHttpClientTransport(Uri.parse('http://127.0.0.1:${inner.mcpPort}/mcp'),
      opts: StreamableHttpClientTransportOptions(requestInit: {'headers': {'Authorization': 'Bearer ${leaf.key}'}})));
    final models = await client.callTool(const CallToolRequest(name: 'list_models'));
    expect((models.content.single as TextContent).text, contains('openai/two'));
    expect((models.content.single as TextContent).text, isNot(contains('local/one')));
    final result = await client.callTool(const CallToolRequest(name: 'chat', arguments: {'prompt': 'Hi'}));
    expect(result.isError, isFalse);
    expect(main.log.first.device, 'Far PC');
  });

  test('UTCP and A2A metadata point at the reachable relay and preserve model restrictions', () async {
    final origin = 'http://127.0.0.1:${inner.port}';
    final manual = await call(inner, '/utcp', key: leaf.key);
    expect(manual.$1, 200);
    expect(manual.$2['tools'][1]['tool_call_template']['url'], '$origin/tools/chat');
    final card = await call(inner, '/.well-known/agent-card.json', key: leaf.key);
    expect(card.$1, 200);
    expect(card.$2['supportedInterfaces'][0]['url'], '$origin/a2a');
    expect(card.$2['skills'].map((s) => s['id']), ['openai/two']);
  });

  test('relay model rules, quotas, and revocation apply to downstream PCs', () async {
    await main.updateAccess(b, ClientAccess(services: {'relay', 'mcp', 'chat'}, requestsPerDay: 0));
    expect((await call(inner, '/v1/chat/completions', key: leaf.key, body: prompt())).$1, 429);
    expect(leaf.usage.requests, 0, reason: 'a failed ancestor reservation must roll back the leaf');
    expect(a.usage.requests, 0);
    await main.updateAccess(b, ClientAccess(services: {'relay', 'mcp', 'chat'}, models: {'local/one'}));
    expect((await call(inner, '/v1/models', key: leaf.key)).$2['data'], isEmpty);
    expect((await call(inner, '/v1/chat/completions', key: leaf.key, body: prompt())).$1, 403);
    await main.updateAccess(b, relayAccess());
    await main.updateAccess(a, ClientAccess(blocked: true, services: {'relay', 'mcp', 'chat'}));
    expect((await call(inner, '/v1/models', key: leaf.key)).$1, 403);
    expect(backend.requests, isEmpty);
  });

  test('blocking a relay interrupts a stalled generation for its descendant', () async {
    backend.hold = Completer<void>();
    final request = call(inner, '/v1/chat/completions', key: leaf.key, body: prompt());
    for (var i = 0; i < 100 && backend.requests.isEmpty; i++) { await Future<void>.delayed(const Duration(milliseconds: 10)); }
    expect(backend.requests, hasLength(1));
    await main.updateAccess(b, ClientAccess(blocked: true, services: {'relay', 'chat', 'mcp'}));
    expect((await request.timeout(const Duration(seconds: 2))).$1, 502);
  });
}

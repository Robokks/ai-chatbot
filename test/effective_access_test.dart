import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/relay_forwarder.dart';
import 'package:ai_chatbot/server/relay_protocol.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'client_access_integration_test.dart' show AccessBackend;

void main() {
  HostServer server() => HostServer(
    AccessBackend(),
    loadDevices: () async => [],
    saveDevices: (_) async {},
  );
  test('effective status intersects inherited rules and reports actual remaining ancestor budget', () async {
    final host = server();
    final today = ClientUsage.dayFor(DateTime.now());
    final early = DateTime.now().add(const Duration(hours: 1));
    final parent = PairedDevice(
      id: 'parent',
      name: 'Parent',
      key: 'parent-key',
      access: ClientAccess(
        services: {'relay', 'chat', 'mcp', 'proxy'},
        tools: {'shared'},
        models: {'openai/two'},
        expires: early,
        requestsPerDay: 100,
        tokensPerDay: 100000,
      ),
      usage: ClientUsage(day: today, requests: 98, tokens: 99000),
    );
    final leaf = PairedDevice(
      id: 'leaf',
      name: 'Leaf',
      key: 'leaf-key',
      via: ['parent'],
      access: ClientAccess(
        services: {'chat', 'mcp'},
        tools: {'shared', 'client'},
        expires: early.add(const Duration(hours: 1)),
        requestsPerDay: 10,
        tokensPerDay: 20000,
      ),
      usage: ClientUsage(day: today, requests: 1, tokens: 100),
    );
    host.devices.addAll([parent, leaf]);
    final status = host.accessStatus(leaf);
    final access = ClientAccess.fromJson(
      status['access'] as Map<String, dynamic>,
    );
    expect(access.models, {'openai/two'});
    expect(access.tools, {'shared'});
    expect(access.services, {'chat', 'mcp'});
    expect(access.expires, early);
    expect(access.requestsPerDay, 10);
    expect(status['remaining'], {
      'requests': 2,
      'tokens': 1000,
      'tokensReserved': false,
    });
    expect(
      leaf.access.models,
      isNull,
      reason: 'effective display never rewrites saved rules',
    );
    parent.access.blocked = true;
    final blocked = host.accessStatus(leaf);
    expect((blocked['access'] as Map)['blocked'], isTrue);
    expect(blocked['models'], isEmpty);
    expect(blocked['denialReason'], contains('blocked'));
    parent.access.blocked = false;
    host.stopAll = true;
    expect(host.accessStatus(leaf)['stopped'], isTrue);
    expect(host.accessStatus(leaf)['denialReason'], contains('stopped'));
    await host.stop();
    host.dispose();
  });
  test('metadata excludes explicit opt-in services from legacy unrestricted rules and exposes reservations', () async {
    final host = server();
    final leaf = await host.createKey('PC');
    var access = ClientAccess.fromJson(
      host.accessStatus(leaf)['access'] as Map<String, dynamic>,
    );
    expect(access.services, contains('chat'));
    for (final restricted in ['relay', 'proxy', 'updates', 'labview']) {
      expect(access.services, isNot(contains(restricted)));
    }
    leaf.access = ClientAccess(tokensPerDay: 20000);
    final reservation = leaf.usage.reserve(
      leaf.access,
      input: {'prompt': 'hello'},
    );
    expect(
      (host.accessStatus(leaf)['remaining'] as Map)['tokensReserved'],
      isTrue,
    );
    reservation.settle(inputTokens: 10, outputTokens: 20);
    expect((host.accessStatus(leaf)['remaining'] as Map)['tokens'], 19970);
    expect(
      (host.accessStatus(leaf)['remaining'] as Map)['tokensReserved'],
      isFalse,
    );
    await host.stop();
    host.dispose();
  });
  test(
    'Main tool choices include shared tools even without client reporting',
    () async {
      final host = HostServer(
        AccessBackend(),
        loadDevices: () async => [],
        saveDevices: (_) async {},
        extraTools: () => [
          const SourceTool(
            name: 'dynasbrain_inspect',
            description: 'Inspect VI',
            inputSchema: {'type': 'object'},
          ),
        ],
      );
      final leaf = await host.createKey('PC');
      leaf.access.tools = {'old_tool'};
      expect(
        host.toolChoicesFor(leaf).keys,
        containsAll(['dynasbrain_inspect', 'old_tool']),
      );
      expect(
        host.toolChoicesFor(leaf)['dynasbrain_inspect'],
        contains('Main LabVIEW'),
      );
      await host.stop();
      host.dispose();
    },
  );
  test('authenticated status remains reachable through blocked relay while model requests stay denied', () async {
    final main = server();
    await main.start(port: 0, address: InternetAddress.loopbackIPv4);
    final parent = await main.createKey('Relay');
    await main.updateAccess(parent, ClientAccess(services: {'relay', 'chat'}));
    final leaf = PairedDevice(
      id: 'leaf',
      name: 'Leaf',
      key: 'leaf-key',
      via: [parent.id],
      access: ClientAccess(approved: false),
    );
    main.devices.add(leaf);
    final relay = server();
    relay.relay = RelayForwarder(
      upstream: Uri.parse('http://127.0.0.1:${main.port}'),
      identity: RelayIdentity(parent.id, parent.key, []),
      mcpPort: () => relay.mcpPort,
    );
    await relay.start(port: 0, address: InternetAddress.loopbackIPv4);
    final http = HttpClient();
    Future<(int, Map)> get(String path) async {
      final request = await http.getUrl(
        Uri.parse('http://127.0.0.1:${relay.port}$path'),
      );
      request.headers.set('authorization', 'Bearer ${leaf.key}');
      final response = await request.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join()) as Map,
      );
    }

    try {
      expect((await get('/access')).$1, 200);
      await main.updateAccess(leaf, ClientAccess(services: {'chat'}));
      await main.updateAccess(
        parent,
        ClientAccess(blocked: true, services: {'relay', 'chat'}),
      );
      final status = await get('/access');
      expect(status.$1, 200);
      expect(status.$2['denialReason'], contains('blocked'));
      expect(status.$2['models'], isEmpty);
      expect((await get('/v1/models')).$1, 403);
      await main.updateAccess(parent, ClientAccess(services: {}));
      expect(
        (await get('/access')).$1,
        200,
        reason: 'removed relay permission still permits only its authenticated leaf status',
      );
      expect((await get('/v1/models')).$1, 403);
    } finally {
      http.close(force: true);
      await relay.stop();
      await main.stop();
      relay.dispose();
      main.dispose();
    }
  });
}

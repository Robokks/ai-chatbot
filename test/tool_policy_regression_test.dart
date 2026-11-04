import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/labview_approval_hub.dart';
import 'package:ai_chatbot/server/relay_forwarder.dart';
import 'package:ai_chatbot/server/relay_protocol.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'client_access_integration_test.dart' show AccessBackend;

void main() {
  test('revoking exact LabVIEW tool cancels pending MCP approval without execution', () async {
    final hub = LabviewApprovalHub();
    var executed = 0;
    final host = HostServer(
      AccessBackend(),
      loadDevices: () async => [],
      saveDevices: (_) async {},
      extraTools: () => [
        const SourceTool(
          name: 'dynasbrain_inspect',
          description: 'Inspect VI',
          inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
        ),
      ],
      runExtraTool: (device, tool, arguments, cancel, recheck) => hub.run(
        device: device,
        tool: tool,
        arguments: arguments,
        cancel: cancel,
        execute: () async {
          recheck();
          executed++;
          return const ToolOutput('done');
        },
      ),
    );
    await host.start(port: 0, address: InternetAddress.loopbackIPv4);
    final pc = await host.createKey('PC');
    await host.updateAccess(
      pc,
      ClientAccess(services: {'mcp', 'labview'}, tools: {'dynasbrain_inspect'}),
    );
    final client = McpClient(const Implementation(name: 'test', version: '1'));
    try {
      await client.connect(
        StreamableHttpClientTransport(
          Uri.parse('http://127.0.0.1:${host.mcpPort}/mcp'),
          opts: StreamableHttpClientTransportOptions(
            requestInit: {
              'headers': {'Authorization': 'Bearer ${pc.key}'},
            },
          ),
        ),
      );
      final call = client.callTool(
        const CallToolRequest(name: 'dynasbrain_inspect', arguments: {}),
      );
      for (var i = 0; i < 200 && hub.pending.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(hub.pending, hasLength(1));
      final pending = hub.pending.single;
      await host.updateAccess(
        pc,
        ClientAccess(services: {'mcp', 'labview'}, tools: {}),
      );
      await Future<void>.delayed(Duration.zero);
      hub.answer(pending, true);
      expect((await call.timeout(const Duration(seconds: 2))).isError, isTrue);
      expect(executed, 0);
      await host.updateAccess(
        pc,
        ClientAccess(
          services: {'mcp', 'labview'},
          tools: {'dynasbrain_inspect'},
        ),
      );
      final approved = client.callTool(
        const CallToolRequest(name: 'dynasbrain_inspect', arguments: {}),
      );
      for (var i = 0; i < 200 && hub.pending.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(hub.pending, hasLength(1));
      hub.answer(hub.pending.single, true);
      // Revoke synchronously after the decision, before its continuation executes.
      await host.updateAccess(
        pc,
        ClientAccess(services: {'mcp', 'labview'}, tools: {}),
      );
      expect(
        (await approved.timeout(const Duration(seconds: 2))).isError,
        isTrue,
      );
      expect(executed, 0);
    } finally {
      await client.close();
      await host.stop();
      host.dispose();
      hub.dispose();
    }
  });
  test('ancestor tool restrictions reject offered schemas for all three model APIs', () async {
    final backend = AccessBackend();
    final main = HostServer(
      backend,
      loadDevices: () async => [],
      saveDevices: (_) async {},
    );
    await main.start(port: 0, address: InternetAddress.loopbackIPv4);
    final parent = await main.createKey('Relay');
    await main.updateAccess(
      parent,
      ClientAccess(services: {'relay', 'chat'}, tools: {}),
    );
    final leaf = PairedDevice(
      id: 'leaf',
      name: 'Leaf',
      key: 'leaf-key',
      via: [parent.id],
      access: ClientAccess(services: {'chat'}, tools: {'denied_tool'}),
    );
    main.devices.add(leaf);
    final relay = HostServer(
      AccessBackend(),
      loadDevices: () async => [],
      saveDevices: (_) async {},
    );
    relay.relay = RelayForwarder(
      upstream: Uri.parse('http://127.0.0.1:${main.port}'),
      identity: RelayIdentity(parent.id, parent.key, []),
      mcpPort: () => relay.mcpPort,
    );
    await relay.start(port: 0, address: InternetAddress.loopbackIPv4);
    final http = HttpClient();
    try {
      final requests = <String, Map<String, dynamic>>{
        '/v1/chat/completions': {
          'model': 'openai/two',
          'messages': [
            {'role': 'user', 'content': 'Hi'},
          ],
          'tools': [
            {
              'type': 'function',
              'function': {
                'name': 'denied_tool',
                'parameters': {
                  'type': 'object',
                  'properties': <String, dynamic>{},
                },
              },
            },
          ],
        },
        '/v1/messages': {
          'model': 'openai/two',
          'max_tokens': 20,
          'messages': [
            {'role': 'user', 'content': 'Hi'},
          ],
          'tools': [
            {
              'name': 'denied_tool',
              'input_schema': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          ],
        },
        '/v1/responses': {
          'model': 'openai/two',
          'input': 'Hi',
          'tools': [
            {
              'type': 'function',
              'name': 'denied_tool',
              'parameters': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          ],
        },
      };
      for (final entry in requests.entries) {
        final request = await http.postUrl(
          Uri.parse('http://127.0.0.1:${relay.port}${entry.key}'),
        );
        request.headers.set('authorization', 'Bearer ${leaf.key}');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(entry.value));
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        expect(response.statusCode, 403, reason: '${entry.key}: $body');
      }
      expect(backend.requests, isEmpty);
    } finally {
      http.close(force: true);
      await relay.stop();
      await main.stop();
      relay.dispose();
      main.dispose();
    }
  });
}

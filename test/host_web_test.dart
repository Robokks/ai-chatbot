import 'dart:io';
import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/tools/builtin_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'client_access_integration_test.dart' show AccessBackend;

void main() {
  test('web search goes through Main and needs a per-PC web grant', () async {
    final dir = await Directory.systemTemp.createTemp('host_web');
    final storage = await Storage.openAt(dir.path);
    var searches = 0;
    final builtin = BuiltinToolSource(storage, client: MockClient((request) async {
      searches++;
      expect(request.url.host, 'html.duckduckgo.com');
      expect(request.bodyFields['q'], 'LabVIEW');
      return http.Response('<div class="result"><a class="result__a" href="https://example.com">LabVIEW help</a><div class="result__snippet">Details</div></div>', 200);
    }));
    final host = HostServer(AccessBackend(), loadDevices: () async => [], saveDevices: (_) async {}, webTools: builtin);
    await host.start(port: 0, address: InternetAddress.loopbackIPv4);
    final device = await host.createKey('Offline PC');
    await host.updateAccess(device, ClientAccess(services: {'mcp'}));
    final client = McpClient(const Implementation(name: 'offline', version: '1'));
    try {
      await client.connect(StreamableHttpClientTransport(Uri.parse('http://127.0.0.1:${host.mcpPort}/mcp'),
        opts: StreamableHttpClientTransportOptions(requestInit: {'headers': {'Authorization': 'Bearer ${device.key}'}})));
      final denied = await client.callTool(const CallToolRequest(name: 'web_search', arguments: {'query': 'LabVIEW'}));
      expect(denied.isError, isTrue);
      expect(searches, 0);
      await host.updateAccess(device, ClientAccess(services: {'mcp', 'web_search'}, tools: {'phone_web_search'}, requestsPerDay: 1));
      final result = await client.callTool(const CallToolRequest(name: 'web_search', arguments: {'query': 'LabVIEW'}));
      expect(result.isError, isFalse);
      expect((result.content.single as TextContent).text, contains('LabVIEW help'));
      expect(searches, 1);
      expect(host.log.first.device, 'Offline PC');
      final quota = await client.callTool(const CallToolRequest(name: 'web_search', arguments: {'query': 'LabVIEW'}));
      expect(quota.isError, isTrue);
      expect(searches, 1);
    } finally {
      await client.close(); await host.stop(); await Hive.close(); await dir.delete(recursive: true);
    }
  });
}

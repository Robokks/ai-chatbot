import 'package:ai_chatbot/server/host_mcp.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';

void main() {
  test('MCP catalog discovers newly shared DynasBrain tools without restarting Main', () async {
    var shared = false;
    final server = HostMcpServer(
      hostName: () => 'Main',
      models: () => [],
      run: (_, _, _) async => ('unused', 'unused'),
      authorize: (_) => true,
      extraToolsFor: () => shared
          ? [
              const SourceTool(
                name: 'dynasbrain_inspect',
                description: 'Inspect actual VI',
                inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
              ),
            ]
          : [],
      runExtraTool: (identity, name, args) async =>
          const ToolOutput('real VI context'),
    );
    await server.start(0);
    Future<McpClient> connect() async {
      final client = McpClient(
        const Implementation(name: 'labview-test', version: '1'),
      );
      await client.connect(
        StreamableHttpClientTransport(
          Uri.parse('http://127.0.0.1:${server.port}/mcp'),
        ),
      );
      return client;
    }

    McpClient? client;
    try {
      client = await connect();
      expect(
        (await client.listTools()).tools.map((t) => t.name),
        isNot(contains('dynasbrain_inspect')),
      );
      await client.close();
      client = null;
      shared = true;
      client = await connect();
      expect(
        (await client.listTools()).tools.map((t) => t.name),
        contains('dynasbrain_inspect'),
      );
      expect(
        ((await client.callTool(
                  const CallToolRequest(
                    name: 'dynasbrain_inspect',
                    arguments: {},
                  ),
                )).content.single
                as TextContent)
            .text,
        'real VI context',
      );
      await client.close();
      client = null;
      shared = false;
      client = await connect();
      expect(
        (await client.listTools()).tools.map((t) => t.name),
        isNot(contains('dynasbrain_inspect')),
      );
    } finally {
      await client?.close();
      await server.stop();
    }
  });
}

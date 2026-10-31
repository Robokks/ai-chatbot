import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import '../data/models.dart';
import 'openai_bridge.dart';

/// Runs one prompt on a shared model and returns the full answer.
typedef RunPrompt = Future<(String text, String model)> Function(
    String? model, String prompt, String? system);

/// MCP server (Streamable HTTP) exposing the host's models as tools, for
/// Claude Desktop, Claude Code, Cursor, VS Code and other MCP clients.
class HostMcpServer {
  HostMcpServer({
    required this.hostName,
    required this.models,
    required this.run,
    required this.authorize,
  });

  final String Function() hostName;
  final List<SharedModel> Function() models;
  final RunPrompt run;
  final bool Function(HttpRequest request) authorize;
  StreamableMcpServer? _server;

  int? get port => _server?.boundPort;

  McpServer _build() {
    final server = McpServer(
      Implementation(name: 'chatbot-host', version: '1.0.0'),
      options: const McpServerOptions(
        capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
      ),
    );
    server.registerTool(
      'list_models',
      description: 'List the AI models shared by ${hostName()}.',
      inputSchema: JsonSchema.object(properties: {}),
      callback: (args, extra) async => CallToolResult(content: [
        TextContent(
          text: jsonEncode([
            for (final m in models())
              {
                'id': m.id,
                'name': m.displayName ?? m.model,
                'runs_on': m.kind == ProviderKind.local ? 'this device' : m.kind.label,
              },
          ]),
        ),
      ]),
    );
    server.registerTool(
      'chat',
      description: 'Ask an AI model on ${hostName()} and get its answer. '
          'Use list_models to see model ids.',
      inputSchema: JsonSchema.object(
        properties: {
          'prompt': JsonSchema.string(description: 'The question or instruction'),
          'model': JsonSchema.string(
              description: 'Model id from list_models; defaults to the first shared model'),
          'system': JsonSchema.string(description: 'Optional system prompt'),
        },
        required: ['prompt'],
      ),
      callback: (args, extra) async {
        try {
          final (text, model) = await run(
            args['model'] as String?,
            args['prompt'] as String,
            args['system'] as String?,
          );
          return CallToolResult(content: [TextContent(text: text)], meta: {'model': model});
        } catch (e) {
          return CallToolResult(content: [TextContent(text: 'Error: $e')], isError: true);
        }
      },
    );
    return server;
  }

  Future<void> start(int port) async {
    final s = _server = StreamableMcpServer(
      serverFactory: (_) => _build(),
      host: '0.0.0.0',
      port: port,
      path: '/mcp',
      authenticator: (request) => authorize(request as HttpRequest),
      // Requests need an access key, so DNS-rebinding pages can't use it;
      // LAN clients connect by IP, which a host allowlist can't predict.
      enableDnsRebindingProtection: false,
    );
    await s.start();
  }

  Future<void> stop() async {
    await _server?.stop();
    _server = null;
  }
}

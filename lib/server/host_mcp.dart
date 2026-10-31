import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import '../data/local/image_engine.dart';
import '../data/models.dart';
import '../tools/tool_source.dart';
import 'coding_agents.dart';
import 'openai_bridge.dart';

/// Runs one prompt on a shared model and returns the full answer.
typedef RunPrompt = Future<(String text, String model)> Function(
    String? model, String prompt, String? system);

/// Runs coding agents (Claude Code, Codex) for paired devices, after the
/// host user approves each run.
abstract class AgentHost {
  AgentSettings get agentSettings;

  /// Agents switched on and found on this PC.
  Set<CodingAgent> get availableAgents;

  Future<ToolOutput> runAgentTask(
    CodingAgent agent,
    AgentFolder folder,
    String task, {
    required String device,
    bool continueLast = false,
    void Function(Duration elapsed, String lastLine)? onProgress,
  });
}

/// The image maker shared by the host.
abstract class HostImages {
  /// Ids of the shared image models (like `local-image/sdxs-...`); empty
  /// when the host doesn't share pictures.
  List<String> sharedImageModels();

  /// Makes one 512×512 PNG for [device].
  Future<MadeImage> makeImage(String? model, String prompt, {int? seed, required String device});
}

/// MCP server (Streamable HTTP) exposing the host's models as tools, for
/// Claude Desktop, Claude Code, Cursor, VS Code and other MCP clients.
class HostMcpServer {
  HostMcpServer({
    required this.hostName,
    required this.models,
    required this.run,
    required this.authorize,
    this.agents,
    this.device,
    this.images,
  });

  final HostImages? images;

  final String Function() hostName;
  final List<SharedModel> Function() models;
  final RunPrompt run;
  final bool Function(HttpRequest request) authorize;
  final AgentHost? agents;

  /// Name of the device whose request was last let in; used to label agent
  /// runs in the host's approval box.
  final String Function()? device;
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
    _registerAgents(server);
    _registerImages(server);
    return server;
  }

  void _registerImages(McpServer server) {
    final host = images;
    if (host == null || host.sharedImageModels().isEmpty) return;
    server.registerTool(
      'create_image',
      description: 'Make a 512x512 picture from a description on ${hostName()} (offline image '
          'model). Returns a PNG.',
      inputSchema: JsonSchema.object(
        properties: {
          'prompt': JsonSchema.string(
              description: 'What the picture shows, e.g. "a red fox in autumn leaves, watercolor"'),
        },
        required: ['prompt'],
      ),
      callback: (args, extra) async {
        try {
          final image = await host.makeImage(null, args['prompt'] as String,
              device: device?.call() ?? 'A paired device');
          return CallToolResult(content: [
            ImageContent(data: base64Encode(image.png), mimeType: 'image/png'),
            TextContent(text: 'Picture made on ${hostName()} (512x512).'),
          ]);
        } catch (e) {
          return CallToolResult(content: [TextContent(text: 'Error: $e')], isError: true);
        }
      },
    );
  }

  void _registerAgents(McpServer server) {
    final host = agents;
    if (host == null) return;
    final deviceName = device?.call() ?? 'A paired device';
    final settings = host.agentSettings;
    if (settings.folders.isEmpty) return;
    for (final agent in host.availableAgents) {
      final folders = [
        for (final f in settings.folders) '"${f.label}" (${f.canEdit ? 'can edit files' : 'read only'})',
      ].join(', ');
      server.registerTool(
        agent.toolName,
        description: 'Give a coding task to ${agent.fullName}, running on ${hostName()} in one of '
            'its project folders: $folders. It reads the code, can run checks and, in '
            'folders that allow it, edit files, then answers with what it found or did. '
            'Describe the task fully; it cannot see this chat. The user on '
            '${hostName()} approves each run. Runs can take several minutes.',
        inputSchema: JsonSchema.object(
          properties: {
            'task': JsonSchema.string(description: 'The full task or question for the agent'),
            'folder': JsonSchema.string(
              description: 'Project folder label',
              enumValues: [for (final f in settings.folders) f.label],
            ),
            if (agent.canContinue)
              'continue_last': JsonSchema.boolean(
                  description: 'Continue the previous ${agent.label} conversation in this folder'),
          },
          required: ['task', 'folder'],
        ),
        annotations: ToolAnnotations(title: agent.label, destructiveHint: true),
        callback: (args, extra) async {
          final folder = host.agentSettings.folder('${args['folder']}');
          final task = '${args['task'] ?? ''}'.trim();
          if (folder == null) {
            return CallToolResult(
                content: [TextContent(text: 'Unknown folder "${args['folder']}". Use one of: $folders')],
                isError: true);
          }
          if (task.isEmpty) {
            return CallToolResult(content: [const TextContent(text: '"task" is required')], isError: true);
          }
          if (!host.availableAgents.contains(agent)) {
            return CallToolResult(
                content: [TextContent(text: '${agent.label} is not shared by ${hostName()} any more.')],
                isError: true);
          }
          final out = await host.runAgentTask(
            agent,
            folder,
            task,
            device: deviceName,
            continueLast: args['continue_last'] == true,
            onProgress: (elapsed, line) {
              final m = elapsed.inMinutes, sec = elapsed.inSeconds % 60;
              extra
                  .sendProgress(elapsed.inSeconds.toDouble(),
                      message: '${agent.label} is working… ${m > 0 ? '${m}m ' : ''}${sec}s'
                          '${line.isEmpty ? '' : ' · ${line.length > 80 ? '${line.substring(0, 80)}…' : line}'}')
                  .catchError((_) {});
            },
          );
          return CallToolResult(content: [TextContent(text: out.text)], isError: out.isError);
        },
      );
    }
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

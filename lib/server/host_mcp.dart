import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../tools/tool_source.dart';
import 'coding_agents.dart';
import 'openai_bridge.dart';

/// Runs one prompt on a shared model and returns the full answer.
typedef RunPrompt = Future<(String text, String model)> Function(
  String? model,
  String prompt,
  String? system,
);

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
    Future<void>? cancel,
    void Function(Duration elapsed, String lastLine)? onProgress,
  });
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
    this.identify,
    this.deviceNameFor,
    this.modelsForIdentity,
    this.runForIdentity,
    this.checkTool,
    this.watchAccess,
    this.webTools = const [],
    this.runWebTool,
    this.extraTools = const [],
    this.extraToolsFor,
    this.runExtraTool,
    this.forward,
  });

  final Future<void> Function(HttpRequest)? forward;
  final String Function() hostName;
  final List<SharedModel> Function() models;
  final RunPrompt run;
  final bool Function(HttpRequest request) authorize;
  final AgentHost? agents;

  final String Function()? device;
  final String? Function(HttpRequest)? identify;
  final String Function(String)? deviceNameFor;
  final List<SharedModel> Function(String)? modelsForIdentity;
  final Future<(String, String)> Function(String, String?, String, String?)?
  runForIdentity;
  final List<SourceTool> extraTools;
  final List<SourceTool> Function()? extraToolsFor;
  List<SourceTool> get _currentExtraTools =>
      extraToolsFor?.call() ?? extraTools;
  final Future<ToolOutput> Function(String, String, Map<String, dynamic>)?
  runExtraTool;
  final List<SourceTool> webTools;
  final Future<ToolOutput> Function(String, String, Map<String, dynamic>)?
  runWebTool;
  final void Function(String, String)? checkTool;
  final VoidCallback Function(String, String, VoidCallback)? watchAccess;
  HttpServer? _server;
  final Map<String, Future<StreamableMcpServer>> _clients = {};
  final Set<HttpClient> _connections = {};
  final Map<String, String> _toolFingerprints = {};
  bool _stopping = false;

  int? get port => _server?.port;

  McpServer _build(String identity) {
    List<SharedModel> allowedModels() =>
        modelsForIdentity?.call(identity) ?? models();
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
      callback: (args, extra) async => CallToolResult(
        content: [
          TextContent(
            text: jsonEncode([
              for (final m in allowedModels())
                {
                  'id': m.id,
                  'name': m.displayName ?? m.model,
                  'runs_on': m.kind == ProviderKind.local
                      ? 'this device'
                      : m.kind.label,
                },
            ]),
          ),
        ],
      ),
    );
    server.registerTool(
      'chat',
      description:
          'Ask an AI model on ${hostName()} and get its answer. '
          'Use list_models to see model ids.',
      inputSchema: JsonSchema.object(
        properties: {
          'prompt': JsonSchema.string(
            description: 'The question or instruction',
          ),
          'model': JsonSchema.string(
            description:
                'Model id from list_models; defaults to the first shared model',
          ),
          'system': JsonSchema.string(description: 'Optional system prompt'),
        },
        required: ['prompt'],
      ),
      callback: (args, extra) async {
        try {
          final runner = runForIdentity == null
              ? run
              : (String? m, String p, String? s) =>
                    runForIdentity!(identity, m, p, s);
          final (text, model) = await runner(
            args['model'] as String?,
            args['prompt'] as String,
            args['system'] as String?,
          );
          return CallToolResult(
            content: [TextContent(text: text)],
            meta: {'model': model},
          );
        } catch (e) {
          return CallToolResult(
            content: [TextContent(text: 'Error: $e')],
            isError: true,
          );
        }
      },
    );
    for (final tool in webTools) {
      server.registerTool(
        tool.name,
        description: tool.description,
        inputSchema: JsonSchema.fromJson(tool.inputSchema) as ToolInputSchema,
        callback: (args, extra) async {
          try {
            final result = await runWebTool!(identity, tool.name, args);
            return CallToolResult(
              content: [TextContent(text: result.text)],
              isError: result.isError,
            );
          } catch (e) {
            return CallToolResult(
              content: [TextContent(text: '$e')],
              isError: true,
            );
          }
        },
      );
    }
    for (final tool in _currentExtraTools) {
      server.registerTool(
        tool.name,
        description: tool.description,
        annotations: ToolAnnotations(destructiveHint: true),
        inputSchema: JsonSchema.fromJson(tool.inputSchema) as ToolInputSchema,
        callback: (args, extra) async {
          var n = 0;
          final ticker = Timer.periodic(const Duration(seconds: 15), (_) {
            extra
                .sendProgress(
                  (++n).toDouble(),
                  message: 'Waiting for Main approval or LabVIEW result',
                )
                .catchError((_) {});
          });
          try {
            final result = await runExtraTool!(identity, tool.name, args);
            return CallToolResult(
              content: [TextContent(text: result.text)],
              isError: result.isError,
            );
          } catch (e) {
            return CallToolResult(
              content: [TextContent(text: '$e')],
              isError: true,
            );
          } finally {
            ticker.cancel();
          }
        },
      );
    }
    _registerAgents(server, identity);
    return server;
  }

  void _registerAgents(McpServer server, String identity) {
    final host = agents;
    if (host == null) return;
    final deviceName =
        deviceNameFor?.call(identity) ?? device?.call() ?? 'A paired device';
    final settings = host.agentSettings;
    if (settings.folders.isEmpty) return;
    for (final agent in host.availableAgents) {
      final folders = [
        for (final f in settings.folders)
          '"${f.label}" (${f.canEdit ? 'can edit files' : 'read only'})',
      ].join(', ');
      server.registerTool(
        agent.toolName,
        description:
            'Give a coding task to ${agent.fullName}, running on ${hostName()} in one of '
            'its project folders: $folders. It reads the code, can run checks and, in '
            'folders that allow it, edit files, then answers with what it found or did. '
            'Describe the task fully; it cannot see this chat. The user on '
            '${hostName()} approves each run. Runs can take several minutes.',
        inputSchema: JsonSchema.object(
          properties: {
            'task': JsonSchema.string(
              description: 'The full task or question for the agent',
            ),
            'folder': JsonSchema.string(
              description: 'Project folder label',
              enumValues: [for (final f in settings.folders) f.label],
            ),
            if (agent.canContinue)
              'continue_last': JsonSchema.boolean(
                description:
                    'Continue the previous ${agent.label} conversation in this folder',
              ),
          },
          required: ['task', 'folder'],
        ),
        annotations: ToolAnnotations(title: agent.label, destructiveHint: true),
        callback: (args, extra) async {
          final folder = host.agentSettings.folder('${args['folder']}');
          final task = '${args['task'] ?? ''}'.trim();
          if (folder == null) {
            return CallToolResult(
              content: [
                TextContent(
                  text:
                      'Unknown folder "${args['folder']}". Use one of: $folders',
                ),
              ],
              isError: true,
            );
          }
          if (task.isEmpty) {
            return CallToolResult(
              content: [const TextContent(text: '"task" is required')],
              isError: true,
            );
          }
          if (!host.availableAgents.contains(agent)) {
            return CallToolResult(
              content: [
                TextContent(
                  text:
                      '${agent.label} is not shared by ${hostName()} any more.',
                ),
              ],
              isError: true,
            );
          }
          checkTool?.call(identity, agent.toolName);
          var progress = 0;
          final cancelled = Completer<void>();
          final unwatch = watchAccess?.call(identity, agent.toolName, () {
            if (!cancelled.isCompleted) cancelled.complete();
          });
          final subscription = extra.signal.onAbort.listen((_) {
            if (!cancelled.isCompleted) cancelled.complete();
          });
          if (extra.signal.aborted && !cancelled.isCompleted) {
            cancelled.complete();
          }
          try {
            final out = await host.runAgentTask(
              agent,
              folder,
              task,
              device: deviceName,
              continueLast: args['continue_last'] == true,
              cancel: cancelled.future,
              onProgress: (elapsed, line) {
                final m = elapsed.inMinutes, sec = elapsed.inSeconds % 60;
                extra
                    .sendProgress(
                      (++progress).toDouble(),
                      message: line.startsWith('Waiting for approval')
                          ? line
                          : '${agent.label} is working… ${m > 0 ? '${m}m ' : ''}${sec}s'
                                '${line.isEmpty ? '' : ' · ${line.length > 80 ? '${line.substring(0, 80)}…' : line}'}',
                    )
                    .catchError((_) {});
              },
            );
            return CallToolResult(
              content: [TextContent(text: out.text)],
              isError: out.isError,
            );
          } finally {
            unwatch?.call();
            await subscription.cancel();
          }
        },
      );
    }
  }

  /// Isolate MCP sessions by authenticated PC, including legacy stateful clients.
  /// Internal servers bind loopback only and repeat the same key/identity checks.
  Future<void> start(int port) async {
    if (_server != null) return;
    _stopping = false;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> _handle(HttpRequest request) async {
    if (forward != null) {
      await forward!(request);
      return;
    }
    HttpClient? client;
    try {
      if (_stopping || request.uri.path != '/mcp') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      if (!authorize(request)) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final identity = identify?.call(request) ?? 'default';
      // Rebuild only this PC's backend when the shared tool catalogue changes.
      // A legacy stateful client must reinitialize after catalogue replacement.
      final fingerprint = jsonEncode([
        for (final tool in _currentExtraTools)
          [tool.name, tool.description, tool.inputSchema],
      ]);
      if (_toolFingerprints[identity] != fingerprint) {
        _toolFingerprints[identity] = fingerprint;
        final previous = _clients.remove(identity);
        if (previous != null) await (await previous).stop();
      }
      final server = await _clients.putIfAbsent(identity, () async {
        final server = StreamableMcpServer(
          serverFactory: (_) => _build(identity),
          host: '127.0.0.1',
          port: 0,
          path: '/mcp',
          authenticator: (req) =>
              authorize(req as HttpRequest) &&
              (identify?.call(req) ?? 'default') == identity,
          enableDnsRebindingProtection: false,
        );
        await server.start();
        return server;
      });
      if (_stopping) throw StateError('MCP is stopping');
      client = HttpClient()..autoUncompress = false;
      _connections.add(client);
      final upstream = await client.openUrl(
        request.method,
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.boundPort,
          path: '/mcp',
          query: request.uri.query.isEmpty ? null : request.uri.query,
        ),
      );
      upstream.followRedirects = false;
      const hopHeaders = {
        'host',
        'content-length',
        'transfer-encoding',
        'connection',
        'keep-alive',
        'proxy-authenticate',
        'proxy-authorization',
        'te',
        'trailer',
        'upgrade',
      };
      request.headers.forEach((name, values) {
        if (!hopHeaders.contains(name.toLowerCase())) {
          upstream.headers.set(name, values);
        }
      });
      var size = 0;
      await for (final bytes in request) {
        size += bytes.length;
        if (size > 25 * 1024 * 1024) {
          request.response.statusCode = 413;
          client.close(force: true);
          await request.response.close();
          return;
        }
        upstream.add(bytes);
      }
      final response = await upstream.close();
      request.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (!hopHeaders.contains(name.toLowerCase())) {
          request.response.headers.set(name, values);
        }
      });
      request.response.bufferOutput = false;
      final activeClient = client;
      unawaited(
        request.response.done.catchError((_) {
          activeClient.close(force: true);
        }),
      );
      await request.response.addStream(response);
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } catch (_) {}
    } finally {
      if (client != null) _connections.remove(client);
      client?.close(force: true);
    }
  }

  Future<void> stop() async {
    _stopping = true;
    await _server?.close(force: true);
    _server = null;
    for (final client in _connections.toList()) {
      client.close(force: true);
    }
    for (final pending in _clients.values.toList()) {
      try {
        await (await pending).stop();
      } catch (_) {}
    }
    _clients.clear();
    _toolFingerprints.clear();
  }
}

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'tool_source.dart';

/// Tools from an MCP server over Streamable HTTP.
class McpToolSource extends ToolSource {
  McpToolSource(super.config, super.secret);

  McpClient? _client;

  Future<McpClient> _connect() async {
    if (_client != null) return _client!;
    final client = McpClient(const Implementation(name: 'chatbot', version: '1.0.0'));
    final transport = StreamableHttpClientTransport(
      Uri.parse(config.url.trim()),
      opts: StreamableHttpClientTransportOptions(requestInit: {
        'headers': {
          if (secret != null && secret!.isNotEmpty) 'Authorization': 'Bearer $secret',
        },
      }),
    );
    await client.connect(transport);
    return _client = client;
  }

  @override
  Future<List<SourceTool>> discover() async {
    final client = await _connect();
    final out = <SourceTool>[];
    String? cursor;
    do {
      final page = await client.listTools(
          params: cursor == null ? null : ListToolsRequest(cursor: cursor));
      for (final t in page.tools) {
        out.add(SourceTool(
          name: t.name,
          description: t.description ?? t.title ?? t.name,
          inputSchema: t.inputSchema.toJson(),
          // Tools that may change things (e.g. a coding agent on the host)
          // always ask first.
          alwaysAsk: t.annotations != null &&
              !t.annotations!.readOnlyHint &&
              t.annotations!.destructiveHint,
        ));
      }
      cursor = page.nextCursor;
    } while (cursor != null && out.length < 500);
    return out;
  }

  @override
  Future<ToolOutput> call(String tool, Map<String, dynamic> arguments) async {
    final client = await _connect();
    final result = await client.callTool(
      CallToolRequest(name: tool, arguments: arguments),
      options: RequestOptions(
        // Long jobs (coding agents) send progress, which keeps the call alive.
        timeout: const Duration(minutes: 2),
        resetTimeoutOnProgress: true,
        maxTotalTimeout: const Duration(minutes: 25),
        onprogress: (p) {
          if (p.message != null) onProgress?.call(p.message!);
        },
      ),
    );
    final imageIds = <String>[];
    final parts = <String>[];
    for (final c in result.content) {
      switch (c) {
        case TextContent(:final text):
          parts.add(text);
        case ImageContent(:final data, :final mimeType):
          final id = await _keepImage(data, mimeType);
          if (id != null) imageIds.add(id);
          parts.add(id == null ? '[image]' : '[picture shown to the user]');
        case AudioContent():
          parts.add('[audio]');
        default:
          parts.add('[${c.runtimeType}]');
      }
    }
    if (result.content.isEmpty && result.structuredContent != null) {
      parts.add(prettyJson(result.structuredContent));
    }
    return ToolOutput(clip(parts.join("\n")), isError: result.isError, imageIds: imageIds);
  }

  Future<String?> _keepImage(String data, String mimeType) async {
    final save = saveImage;
    if (save == null || mimeType != 'image/png') {
      return null;
    }
    try {
      return await save(base64Decode(data), mimeType);
    } catch (_) {
      return null;
    }
  }

  @override
  Duration get callTimeout => const Duration(minutes: 26);

  @override
  Future<void> close() async {
    await _client?.close();
    _client = null;
  }
}

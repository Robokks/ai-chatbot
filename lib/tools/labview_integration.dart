import 'dart:io';

import '../core/storage.dart';
import 'tool_registry.dart';
import 'tool_source.dart';

/// Uses DynasBrain's real Streamable HTTP MCP interface, without launching it.
class LabviewIntegration {
  LabviewIntegration(this.storage, this.tools);
  final Storage storage;
  final ToolRegistry tools;
  static const sourceId = 'labview-dynasbrain';
  static const expertPrompt =
      '''You are a LabVIEW engineering assistant. Help with block diagrams, dataflow, type definitions, state machines, producer/consumer designs, hardware I/O and test automation. First establish the LabVIEW version, target, hardware and actual VI context. Use available DynasBrain MCP tools to inspect the project before suggesting edits. Never invent VI names, connector panes, tool APIs or measurement results. If inspection is unavailable, explain what information is missing. Keep units, timing, error clusters, resource cleanup and instrument limits explicit. Before changing a VI, writing hardware outputs, running an experiment or modifying a project, describe the effect and request approval. Prefer small reversible changes and explain how to validate them without risking hardware.''';
  static Uri endpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/mcp' ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException(
        'Enter an HTTP(S) DynasBrain URL ending in /mcp, without keys or query parameters.',
      );
    }
    final ip = InternetAddress.tryParse(uri.host);
    final bytes = ip?.rawAddress;
    final localV4 =
        bytes?.length == 4 &&
        (bytes![0] == 10 ||
            bytes[0] == 127 ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168));
    final localV6 =
        ip?.type == InternetAddressType.IPv6 &&
        (ip!.isLoopback || (bytes![0] & 0xfe) == 0xfc);
    if (uri.host != 'localhost' && !localV4 && !localV6) {
      throw const FormatException(
        'Use localhost or a private lab IP address. Public hosts and DNS names are not accepted.',
      );
    }
    return uri;
  }

  ToolSourceConfig? get config =>
      tools.configs.where((c) => c.id == sourceId).firstOrNull;
  bool get shared => storage.getSetting('labview.shared') == 'true';
  Future<void> setShared(bool value) =>
      storage.setSetting('labview.shared', '$value');
  Future<void> connect(String url, {String? key}) async {
    final uri = endpoint(url);
    await tools.addOrUpdate(
      ToolSourceConfig(
        id: sourceId,
        type: ToolSourceType.mcp,
        name: 'DynasBrain LabVIEW',
        url: uri.toString(),
        askBeforeRun: true,
      ),
      secret: key,
    );
  }

  /// Session status is deliberately distinct from a saved endpoint.
  String get connectionStatus {
    final saved = config;
    if (saved == null) return 'Not configured';
    if (!saved.enabled) return 'Disabled';
    final status = tools.status[sourceId];
    if (status == null) return 'Not checked in this app session';
    if (status.loading) return 'Checking MCP connection…';
    if (status.error != null) return 'Connection failed: ${status.error}';
    if (status.tools.isEmpty) return 'Connected; DynasBrain returned no tools';
    return 'Connected · ${status.tools.length} MCP tools discovered';
  }

  String get diagnosticHint {
    final error = tools.status[sourceId]?.error?.toLowerCase() ?? '';
    if (error.contains('access denied')) {
      return 'Check the DynasBrain access key and reconnect.';
    }
    if (error.contains('timed out') ||
        error.contains('connection refused') ||
        error.contains('socket')) {
      return 'Check that dynasbrain serve is running, the port matches its output, and the LabVIEW PC firewall allows this connection.';
    }
    if (error.isNotEmpty) {
      return 'Check the /mcp URL against DynasBrain’s server output. This app requires Streamable HTTP MCP.';
    }
    return 'This check discovers tools only. It does not verify that LabVIEW, an instrument, or a VI is ready.';
  }

  bool expertSelected(String current) =>
      storage.getSetting('labview.preset.active') == current &&
      current.isNotEmpty;

  /// Preserve the user's prompt and restore it only if they have not edited it.
  Future<void> selectExpert(
    bool enabled, {
    required String current,
    required Future<void> Function(String) writePrompt,
  }) async {
    if (enabled) {
      if (expertSelected(current)) return;
      final composed = current.trim().isEmpty
          ? expertPrompt
          : '$current\n\n$expertPrompt';
      await storage.setSetting('labview.preset.previous', current);
      await storage.setSetting('labview.preset.active', composed);
      await writePrompt(composed);
    } else {
      if (expertSelected(current)) {
        await writePrompt(storage.getSetting('labview.preset.previous') ?? '');
      }
      await storage.setSetting('labview.preset.active', '');
      await storage.setSetting('labview.preset.previous', '');
    }
  }

  List<LabviewSharedTool> sharedTools() => !shared
      ? const []
      : [
          for (final spec in tools.activeTools())
            if (spec.sourceId == sourceId)
              LabviewSharedTool(
                name: spec.name,
                description: spec.description,
                inputSchema: spec.inputSchema,
              ),
        ];
}

class LabviewSharedTool {
  const LabviewSharedTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

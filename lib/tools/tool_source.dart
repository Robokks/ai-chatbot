import 'dart:convert';

enum ToolSourceType {
  mcp('MCP server'),
  utcp('UTCP manual'),
  a2a('A2A agent'),
  cli('CLI program');

  const ToolSourceType(this.label);
  final String label;
}

/// Saved settings for one tool source. Secrets (keys) are stored separately.
class ToolSourceConfig {
  ToolSourceConfig({
    required this.id,
    required this.type,
    required this.name,
    this.url = '',
    this.enabled = true,
    bool? askBeforeRun,
    this.description = '',
    Map<String, String>? variables,
  })  : askBeforeRun = askBeforeRun ?? type == ToolSourceType.cli,
        variables = variables ?? {};

  final String id;
  final ToolSourceType type;
  String name;

  /// MCP endpoint, UTCP manual URL, A2A agent card URL, or the CLI program.
  String url;
  bool enabled;

  /// Ask before each run (always on for CLI programs).
  bool askBeforeRun;

  /// CLI: what the program does, shown to the model.
  String description;

  /// UTCP: values for `${VAR}` placeholders (non-secret).
  final Map<String, String> variables;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'name': name,
        'url': url,
        'enabled': enabled,
        'ask': askBeforeRun,
        if (description.isNotEmpty) 'description': description,
        if (variables.isNotEmpty) 'variables': variables,
      };

  factory ToolSourceConfig.fromJson(Map<String, dynamic> j) => ToolSourceConfig(
        id: j['id'] as String,
        type: ToolSourceType.values.byName(j['type'] as String),
        name: j['name'] as String,
        url: j['url'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
        askBeforeRun: j['ask'] as bool?,
        description: j['description'] as String? ?? '',
        variables: (j['variables'] as Map?)?.map((k, v) => MapEntry('$k', '$v')),
      );
}

/// A tool as a source describes it, before it gets a model-facing name.
class SourceTool {
  const SourceTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.alwaysAsk = false,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  /// Runs local commands: always needs the user's approval.
  final bool alwaysAsk;
}

class ToolOutput {
  const ToolOutput(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

/// Something that offers tools: an MCP server, a UTCP manual, an A2A agent
/// or an allowlisted CLI program.
abstract class ToolSource {
  ToolSource(this.config, this.secret);

  final ToolSourceConfig config;

  /// API key / bearer token, if any.
  final String? secret;

  /// Finds the tools this source offers.
  Future<List<SourceTool>> discover();

  Future<ToolOutput> call(String tool, Map<String, dynamic> arguments);

  Future<void> close() async {}
}

/// Limits tool output sent back to the model.
String clip(String text, [int max = 20000]) =>
    text.length <= max ? text : '${text.substring(0, max)}\n… [${text.length - max} more characters cut]';

String prettyJson(Object? v) => const JsonEncoder.withIndent('  ').convert(v);

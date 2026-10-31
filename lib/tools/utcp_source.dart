import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'cli_runner.dart';
import 'tool_source.dart';

/// Tools from a UTCP manual (https://www.utcp.io). HTTP tools are called
/// directly; CLI tools run on a PC when every program they use is on the
/// user's CLI allowlist.
class UtcpToolSource extends ToolSource {
  UtcpToolSource(super.config, super.secret, {required this.allowedPrograms, http.Client? client})
      : _client = client ?? http.Client();

  /// Program names allowed by the user's CLI tools (e.g. "git", "python").
  final Set<String> allowedPrograms;
  final http.Client _client;
  final Map<String, Map<String, dynamic>> _templates = {};
  final Map<String, String> _oauthTokens = {};

  /// Tools that were left out, with the reason (shown in Settings).
  final List<String> skipped = [];

  @override
  Future<List<SourceTool>> discover() async {
    final res = await _client.get(Uri.parse(config.url.trim()), headers: {
      'accept': 'application/json',
      if (secret != null && secret!.isNotEmpty) 'authorization': 'Bearer $secret',
    }).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw HttpException('Manual not found (status ${res.statusCode})');
    final manual = jsonDecode(res.body);
    if (manual is! Map || manual['tools'] is! List) {
      throw const FormatException('Not a UTCP manual (no "tools" list)');
    }
    _templates.clear();
    skipped.clear();
    final out = <SourceTool>[];
    for (final t in manual['tools'] as List) {
      if (t is! Map || t['name'] is! String) continue;
      final name = t['name'] as String;
      final tpl = Map<String, dynamic>.from(
          (t['tool_call_template'] ?? t['tool_provider'] ?? const {}) as Map);
      final type = tpl['call_template_type'] ?? tpl['provider_type'];
      final isCli = type == 'cli';
      if (type != 'http' && !isCli) {
        skipped.add('$name: "$type" tools are not supported');
        continue;
      }
      if (isCli) {
        final problem = _cliProblem(tpl);
        if (problem != null) {
          skipped.add('$name: $problem');
          continue;
        }
      }
      _templates[name] = tpl;
      out.add(SourceTool(
        name: name,
        description: t['description'] as String? ?? name,
        inputSchema: Map<String, dynamic>.from(
            (t['inputs'] ?? {'type': 'object', 'properties': {}}) as Map),
        alwaysAsk: isCli,
      ));
    }
    return out;
  }

  String? _cliProblem(Map<String, dynamic> tpl) {
    if (!cliSupported) return 'command-line tools only run on a PC';
    final commands = tpl['commands'] as List? ?? const [];
    if (commands.isEmpty) return 'no commands';
    for (final c in commands) {
      final cmd = c is Map ? c['command'] as String? ?? '' : '$c';
      final program = programOf(cmd);
      if (!allowedPrograms.contains(program) && !_builtins.contains(program)) {
        return '"$program" is not on your CLI allowlist';
      }
    }
    return null;
  }

  /// Replaces `${VAR}` with the source's variables, falling back to its key.
  String _vars(String text) => text.replaceAllMapped(RegExp(r'\$\{([A-Za-z0-9_]+)\}'), (m) {
        return config.variables[m[1]] ?? secret ?? '';
      });

  @override
  Future<ToolOutput> call(String tool, Map<String, dynamic> arguments) async {
    final tpl = _templates[tool];
    if (tpl == null) return const ToolOutput('Unknown tool', isError: true);
    final type = tpl['call_template_type'] ?? tpl['provider_type'];
    return type == 'cli' ? _callCli(tpl, arguments) : _callHttp(tpl, arguments);
  }

  Future<ToolOutput> _callHttp(Map<String, dynamic> tpl, Map<String, dynamic> arguments) async {
    final args = Map<String, dynamic>.from(arguments);
    var url = _vars(tpl['url'] as String? ?? '');
    // 1. Path parameters.
    url = url.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (m) {
      final v = args.remove(m[1]);
      return v == null ? m[0]! : Uri.encodeComponent('$v');
    });
    final method = (tpl['http_method'] as String? ?? 'GET').toUpperCase();
    final headers = <String, String>{
      for (final e in (tpl['headers'] as Map? ?? const {}).entries) '${e.key}': _vars('${e.value}'),
    };
    // 2. Body field.
    Object? body;
    final bodyField = tpl['body_field'] as String?;
    if (bodyField != null && args.containsKey(bodyField)) body = args.remove(bodyField);
    // 3. Header fields.
    for (final h in (tpl['header_fields'] as List? ?? const []).cast<String>()) {
      final v = args.remove(h);
      if (v != null) headers[h] = '$v';
    }
    // 4. Everything else is a query parameter.
    var uri = Uri.parse(url);
    final query = {...uri.queryParameters};
    for (final e in args.entries) {
      query[e.key] = e.value is String ? e.value as String : jsonEncode(e.value);
    }
    await _applyAuth(tpl['auth'] as Map?, headers, query);
    uri = uri.replace(queryParameters: query.isEmpty ? null : query);

    final req = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) {
      final contentType = tpl['content_type'] as String? ?? 'application/json';
      req.headers['content-type'] = contentType;
      req.body = body is String && !contentType.contains('json') ? body : jsonEncode(body);
    }
    final res = await http.Response.fromStream(
        await _client.send(req).timeout(const Duration(minutes: 2)));
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    return ToolOutput(
      clip(ok ? res.body : 'HTTP ${res.statusCode}: ${res.body}'),
      isError: !ok,
    );
  }

  Future<void> _applyAuth(Map? auth, Map<String, String> headers, Map<String, String> query) async {
    if (auth == null) return;
    switch (auth['auth_type']) {
      case 'api_key':
        final value = _vars('${auth['api_key'] ?? ''}');
        final name = '${auth['var_name'] ?? 'X-Api-Key'}';
        switch (auth['location'] ?? 'header') {
          case 'query':
            query[name] = value;
          case 'cookie':
            headers['cookie'] = '$name=$value';
          default:
            headers[name] = value;
        }
      case 'basic':
        final user = _vars('${auth['username'] ?? ''}'), pass = _vars('${auth['password'] ?? ''}');
        headers['authorization'] = 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';
      case 'oauth2':
        headers['authorization'] = 'Bearer ${await _oauthToken(auth)}';
    }
  }

  Future<String> _oauthToken(Map auth) async {
    final tokenUrl = _vars('${auth['token_url']}');
    final cached = _oauthTokens[tokenUrl];
    if (cached != null) return cached;
    final res = await _client.post(Uri.parse(tokenUrl), body: {
      'grant_type': 'client_credentials',
      'client_id': _vars('${auth['client_id'] ?? ''}'),
      'client_secret': _vars('${auth['client_secret'] ?? ''}'),
      if (auth['scope'] != null) 'scope': '${auth['scope']}',
    });
    final token = (jsonDecode(res.body) as Map)['access_token'] as String?;
    if (token == null) throw HttpException('OAuth token request failed (${res.statusCode})');
    return _oauthTokens[tokenUrl] = token;
  }

  /// Shell built-ins that only move around or print, allowed without listing.
  static const _builtins = {'cd', 'echo', 'printf', 'set-location', 'write-output', 'pwd'};

  /// Runs all commands as one shell script so `cd` carries over and earlier
  /// outputs are available as `$CMD_<n>_OUTPUT` (UTCP CLI semantics).
  Future<ToolOutput> _callCli(Map<String, dynamic> tpl, Map<String, dynamic> args) async {
    final commands = [
      for (final c in tpl['commands'] as List)
        (
          command: (c is Map ? c['command'] as String : '$c').replaceAllMapped(
            RegExp(r'UTCP_ARG_([A-Za-z0-9_]+)_UTCP_END'),
            (m) {
              final v = args[m[1]];
              return shellQuote(v == null ? '' : (v is String ? v : jsonEncode(v)));
            },
          ),
          append: c is Map ? c['append_to_final_output'] as bool? : null,
        ),
    ];
    final finals = [
      for (final (i, c) in commands.indexed)
        if (c.append ?? i == commands.length - 1) i,
    ];
    final String script;
    if (Platform.isWindows) {
      script = [
        for (final (i, c) in commands.indexed) '\$CMD_${i}_OUTPUT = (${c.command} 2>&1 | Out-String)',
        for (final i in finals) 'Write-Output \$CMD_${i}_OUTPUT',
      ].join('\n');
    } else {
      script = [
        r'__out=$(mktemp)',
        for (final (i, c) in commands.indexed) ...[
          '${c.command} > "\$__out" 2>&1',
          'CMD_${i}_OUTPUT=\$(cat "\$__out")',
        ],
        for (final i in finals) 'printf \'%s\\n\' "\$CMD_${i}_OUTPUT"',
        r'rm -f "$__out"',
      ].join('\n');
    }
    return Platform.isWindows
        ? runProcess('powershell', ['-NoProfile', '-Command', script],
            workingDirectory: tpl['working_dir'] as String?)
        : runProcess('sh', ['-c', script], workingDirectory: tpl['working_dir'] as String?);
  }

  /// The script preview shown when asking for approval.
  String? cliPreview(String tool, Map<String, dynamic> args) {
    final tpl = _templates[tool];
    if (tpl == null || (tpl['call_template_type'] ?? tpl['provider_type']) != 'cli') return null;
    return [
      for (final c in tpl['commands'] as List)
        (c is Map ? c['command'] as String : '$c').replaceAllMapped(
          RegExp(r'UTCP_ARG_([A-Za-z0-9_]+)_UTCP_END'),
          (m) => shellQuote('${args[m[1]] ?? ''}'),
        ),
    ].join('\n');
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/storage.dart';
import '../data/models.dart';
import 'a2a_source.dart';
import 'builtin_source.dart';
import 'cli_runner.dart';
import 'cli_source.dart';
import 'termux.dart';
import 'mcp_source.dart';
import 'tool_source.dart';
import 'utcp_source.dart';

/// Connection state of one source, for the Tools screen.
class SourceStatus {
  bool loading = false;
  String? error;
  List<SourceTool> tools = const [];
  List<String> skipped = const [];
}

/// All tool sources the user added, and the tools they currently offer.
class ToolRegistry extends ChangeNotifier {
  ToolRegistry(this.storage, {this.sourceFactory, BuiltinToolSource? builtin})
      : builtin = builtin ?? BuiltinToolSource(storage);

  final Storage storage;

  /// Web search, calculator, notes… always available, no setup.
  final BuiltinToolSource builtin;

  /// Built-in tools the user switched off.
  final Set<String> disabledBuiltins = {};

  static const builtinId = 'builtin';

  /// Overrides how sources are built (tests).
  final ToolSource Function(ToolSourceConfig config, String? secret)? sourceFactory;

  final List<ToolSourceConfig> configs = [];
  final Map<String, SourceStatus> status = {};
  final Map<String, ToolSource> _live = {};

  /// Model-facing name → (source id, tool name).
  final Map<String, (String, String)> _routes = {};

  /// Master switch: offer tools to the AI at all.
  bool enabled = true;

  Future<void> load() async {
    await TermuxRunner.refresh();
    final raw = storage.getSetting('tools.sources');
    configs
      ..clear()
      ..addAll([
        if (raw != null)
          for (final e in jsonDecode(raw) as List)
            ToolSourceConfig.fromJson(Map<String, dynamic>.from(e as Map)),
      ]);
    enabled = storage.getSetting('tools.enabled') != 'false';
    final off = storage.getSetting('tools.builtinOff');
    disabledBuiltins
      ..clear()
      ..addAll(off == null ? const [] : (jsonDecode(off) as List).cast<String>());
    notifyListeners();
  }

  Future<void> setBuiltinEnabled(String tool, bool v) async {
    v ? disabledBuiltins.remove(tool) : disabledBuiltins.add(tool);
    await storage.setSetting('tools.builtinOff', jsonEncode(disabledBuiltins.toList()));
    notifyListeners();
  }

  Future<void> _save() async {
    await storage.setSetting('tools.sources', jsonEncode([for (final c in configs) c.toJson()]));
    await storage.setSetting('tools.enabled', '$enabled');
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    await _save();
    notifyListeners();
  }

  /// Programs the user allowed as CLI tools (also used by UTCP CLI tools).
  Set<String> get allowedPrograms => {
        for (final c in configs)
          if (c.type == ToolSourceType.cli && c.enabled) programOf(c.url),
      };

  Future<void> addOrUpdate(ToolSourceConfig config, {String? secret}) async {
    final i = configs.indexWhere((c) => c.id == config.id);
    i >= 0 ? configs[i] = config : configs.add(config);
    if (secret != null) await storage.writeSecret('tool.${config.id}', secret);
    await _save();
    await _drop(config.id);
    notifyListeners();
    if (config.enabled) await connect(config);
  }

  Future<void> remove(ToolSourceConfig config) async {
    configs.removeWhere((c) => c.id == config.id);
    await storage.writeSecret('tool.${config.id}', null);
    await _drop(config.id);
    status.remove(config.id);
    await _save();
    notifyListeners();
  }

  Future<void> setSourceEnabled(ToolSourceConfig config, bool v) async {
    config.enabled = v;
    await _save();
    if (v) {
      await connect(config);
    } else {
      await _drop(config.id);
    }
    notifyListeners();
  }

  Future<void> setAsk(ToolSourceConfig config, bool v) async {
    config.askBeforeRun = config.type == ToolSourceType.cli || v;
    await _save();
    notifyListeners();
  }

  Future<void> _drop(String id) async {
    try {
      await _live.remove(id)?.close();
    } catch (_) {}
  }

  ToolSource _build(ToolSourceConfig c, String? secret) =>
      sourceFactory?.call(c, secret) ??
      switch (c.type) {
        ToolSourceType.mcp => McpToolSource(c, secret),
        ToolSourceType.utcp => UtcpToolSource(c, secret, allowedPrograms: allowedPrograms),
        ToolSourceType.a2a => A2aToolSource(c, secret),
        ToolSourceType.cli => CliToolSource(c, secret),
      };

  /// Connects [config] and lists its tools.
  Future<void> connect(ToolSourceConfig config) async {
    final st = status.putIfAbsent(config.id, SourceStatus.new)
      ..loading = true
      ..error = null;
    notifyListeners();
    try {
      await _drop(config.id);
      final source = _live[config.id] =
          _build(config, await storage.readSecret('tool.${config.id}'));
      st.tools = await source.discover().timeout(const Duration(seconds: 30));
      st.skipped = source is UtcpToolSource ? List.of(source.skipped) : const [];
    } catch (e) {
      st
        ..tools = const []
        ..error = _friendly(e);
    } finally {
      st.loading = false;
      notifyListeners();
    }
  }

  /// Connects every enabled source that isn't connected yet.
  Future<void> connectAll() => Future.wait([
        for (final c in configs)
          if (c.enabled && !_live.containsKey(c.id) && !(status[c.id]?.loading ?? false)) connect(c),
      ]);

  static String _friendly(Object e) {
    final s = e.toString();
    if (e is TimeoutException) return 'No answer (timed out)';
    if (s.contains('401') || s.contains('403')) return 'Access denied: check the key';
    return s.replaceFirst(RegExp(r'^\w*(Exception|Error): '), '');
  }

  static String _slug(String s) {
    final v = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return v.isEmpty ? 'tool' : v;
  }

  /// Tools to offer the AI this turn, with unique model-facing names.
  List<ToolSpec> activeTools() {
    _routes.clear();
    if (!enabled) return const [];
    final out = <ToolSpec>[
      for (final t in builtin.tools)
        if (!disabledBuiltins.contains(t.name))
          ToolSpec(
            name: 'phone_${t.name}',
            description: t.description,
            inputSchema: t.inputSchema,
            sourceId: builtinId,
            sourceLabel: 'Built-in',
            needsApproval: t.alwaysAsk,
          ),
    ];
    for (final t in out) {
      _routes[t.name] = (builtinId, t.name.substring(6));
    }
    for (final c in configs) {
      if (!c.enabled || !_live.containsKey(c.id)) continue;
      for (final t in status[c.id]?.tools ?? const <SourceTool>[]) {
        var name = '${_slug(c.name)}_${t.name}'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        if (name.length > 64) name = name.substring(0, 64);
        var unique = name;
        for (var i = 2; _routes.containsKey(unique); i++) {
          unique = '${name.substring(0, name.length.clamp(0, 60))}_$i';
        }
        _routes[unique] = (c.id, t.name);
        out.add(ToolSpec(
          name: unique,
          description: t.description,
          inputSchema: t.inputSchema,
          sourceId: c.id,
          sourceLabel: '${c.type.label} · ${c.name}',
          needsApproval: t.alwaysAsk || c.askBeforeRun || c.type == ToolSourceType.cli,
        ));
      }
    }
    return out;
  }

  /// Name of the source a tool comes from, for display.
  String? sourceNameFor(String toolName) {
    final route = _routes[toolName];
    if (route == null) return null;
    if (route.$1 == builtinId) return 'Built-in';
    return configFor(toolName)?.name;
  }

  ToolSourceConfig? configFor(String toolName) {
    final route = _routes[toolName];
    return route == null ? null : configs.where((c) => c.id == route.$1).firstOrNull;
  }

  /// Human-readable description of what a call will do (for approval).
  String describe(ToolCall call) {
    final route = _routes[call.name];
    final source = route == null ? null : _live[route.$1];
    if (source is CliToolSource) return CliToolSource.preview(source.config.url, call.arguments);
    if (source is UtcpToolSource) {
      final script = source.cliPreview(route!.$2, call.arguments);
      if (script != null) return script;
    }
    return prettyJson(call.arguments);
  }

  Future<ToolResult> execute(ToolCall call, {void Function(String message)? onProgress}) async {
    final route = _routes[call.name];
    if (route?.$1 == builtinId) {
      try {
        final out = await builtin.call(route!.$2, call.arguments).timeout(const Duration(minutes: 1));
        return ToolResult(callId: call.id, name: call.name, text: out.text, isError: out.isError);
      } catch (e) {
        return ToolResult(callId: call.id, name: call.name, text: 'Tool failed: ${_friendly(e)}', isError: true);
      }
    }
    final source = route == null ? null : _live[route.$1];
    if (source == null) {
      return ToolResult(callId: call.id, name: call.name, text: 'Unknown tool "${call.name}"', isError: true);
    }
    source.onProgress = onProgress;
    try {
      final out = await source.call(route!.$2, call.arguments).timeout(source.callTimeout);
      return ToolResult(callId: call.id, name: call.name, text: out.text, isError: out.isError);
    } on TimeoutException {
      return ToolResult(callId: call.id, name: call.name, text: 'The tool timed out.', isError: true);
    } catch (e) {
      return ToolResult(callId: call.id, name: call.name, text: 'Tool failed: ${_friendly(e)}', isError: true);
    } finally {
      source.onProgress = null;
    }
  }

  @override
  void dispose() {
    for (final s in _live.values) {
      s.close();
    }
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/storage.dart';
import '../core/theme.dart';
import '../data/llm/demo_provider.dart';
import '../data/llm/llm_provider.dart';
import '../data/llm/named_sources.dart';
import '../data/llm/local_provider.dart';
import '../data/local/local_models.dart';
import '../data/models.dart';
import '../data/lab_role.dart';
import '../server/discovery.dart';
import '../server/lab_analytics.dart';
import '../server/host_controller.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_source.dart';
import '../tools/mcp_source.dart';
import '../server/client_connection.dart';

const demoMode = bool.fromEnvironment('DEMO');

/// App-wide state: settings, provider keys, conversations and the active
/// streaming reply.
class AppState extends ChangeNotifier {
  AppState(
    this.storage, {
    LlmProvider Function(ProviderSettings, String)? providerFactory,
    LocalModelStore? localModels,
    ToolRegistry? tools,
    NamedSources? sources,
  })  : localModels = localModels ?? LocalModelStore(storage),
        tools = tools ?? ToolRegistry(storage),
        sources = sources ?? NamedSources(storage) {
    _providerFactory = providerFactory ?? _defaultProvider;
    this.localModels.addListener(_syncLocalModels);
    this.tools.hostWeb = _hostWeb;
    this.sources.addListener(notifyListeners);
  }

  final Storage storage;
  final NamedSources sources;

  /// Host mode: sharing this device's models on the local network.
  late final HostController host = HostController(this);

  /// MCP servers, UTCP manuals, A2A agents and CLI programs the AI can use.
  final ToolRegistry tools;

  /// GGUF models downloaded to this device.
  final LocalModelStore localModels;
  late final LlmProvider Function(ProviderSettings, String) _providerFactory;

  /// On-device models run natively; the web build has no llama.cpp.
  static bool get localSupported => !kIsWeb;

  LlmProvider _defaultProvider(ProviderSettings s, String key) {
    if (demoMode) return DemoProvider(s);
    if (s.kind == ProviderKind.local) {
      return LocalProvider(settings: s, pathFor: localModels.pathFor);
    }
    return LlmProvider.create(s, key);
  }

  final Map<ProviderKind, ProviderSettings> providers = {};
  final Map<ProviderKind, String> _keys = {};
  List<Conversation> conversations = [];
  Conversation? current;

  ThemeMode themeMode = ThemeMode.system;
  AppThemeStyle themeStyle = AppThemeStyle.cream;
  LabRole? labRole;
  String systemPrompt = '';
  ProviderKind provider = ProviderKind.anthropic;
  String model = ProviderKind.anthropic.models.first;

  StreamSubscription<ChatDelta>? _sub;
  LlmProvider? _activeProvider;
  Completer<void>? _done;
  Message? streamingMessage;
  bool get isStreaming => streamingMessage != null;

  /// Shown beside the typing indicator, e.g. "Loading model…".
  String? streamingStatus;

  /// Times the reply being streamed.
  Stopwatch? _clock;
  bool _stopped = false;

  Future<void> load() async {
    for (final k in ProviderKind.values) {
      providers[k] = storage.providerSettings(k);
      final key = await storage.readKey(k);
      if (key != null && key.isNotEmpty) _keys[k] = key;
    }
    themeMode = ThemeMode.values.asNameMap()[storage.getSetting('theme')] ??
        ThemeMode.system;
    themeStyle = AppThemeStyle.values.asNameMap()[storage.getSetting('themeStyle')] ??
        AppThemeStyle.cream;
    labRole = LabRole.values.asNameMap()[storage.getSetting('lab.role')];
    systemPrompt = storage.getSetting('systemPrompt') ?? '';
    provider = ProviderKind.values.asNameMap()[storage.getSetting('provider')] ??
        ProviderKind.anthropic;
    model = storage.getSetting('model') ?? providers[provider]!.models.firstOrNull ?? '';
    conversations = storage.loadConversations();
    await sources.load();
    await tools.load();
    if (!demoMode) unawaited(tools.connectAll());
    if (localSupported) {
      try {
        await localModels.load();
      } catch (_) {
        // No model folder (e.g. sandboxed tests): on-device models stay hidden.
      }
    }
    _syncLocalModels();
  }

  /// Mirrors installed GGUF files into the On-device provider's model list.
  void _syncLocalModels() {
    final ids = [
      for (final m in localModels.all)
        if (localModels.installed.contains(m.id)) m.id,
    ];
    providers[ProviderKind.local] = ProviderSettings(kind: ProviderKind.local, models: ids);
    if (provider == ProviderKind.local && !ids.contains(model) && !demoMode) {
      final fallback = ProviderKind.values.firstWhere(
          (k) => k != ProviderKind.local && hasKey(k),
          orElse: () => ProviderKind.anthropic);
      provider = fallback;
      model = providers[fallback]!.models.first;
    }
    notifyListeners();
  }

  // Settings

  bool hasKey(ProviderKind k) {
    if (k == ProviderKind.local) {
      return localSupported && localModels.installed.isNotEmpty;
    }
    return demoMode || k == ProviderKind.custom || (_keys[k]?.isNotEmpty ?? false);
  }
  String keyFor(ProviderKind k) => _keys[k] ?? '';

  @override
  void dispose() {
    _activeProvider?.client.close();
    localModels.removeListener(_syncLocalModels);
    sources.removeListener(notifyListeners);
    super.dispose();
  }

  Future<void> setKey(ProviderKind k, String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      _keys.remove(k);
    } else {
      _keys[k] = v;
    }
    await storage.writeKey(k, v);
    notifyListeners();
  }

  Future<void> updateProviderSettings(ProviderSettings s) async {
    providers[s.kind] = s;
    await storage.saveProviderSettings(s);
    notifyListeners();
  }

  /// A provider ready to chat with [k] using its saved settings and key.
  LlmProvider providerFor(ProviderKind k, {String? modelId}) {
    final route = modelId ?? (k == provider ? model : '');
    if (route.startsWith('auto:')) return sources.routingProvider(route);
    final source = sources.forRoute(k, route);
    if (route.startsWith('source:') && source == null) throw LlmException('This AI source is no longer available.');
    return source == null ? _providerFactory(providers[k]!, keyFor(k)) : sources.provider(source, route);
  }

  /// Name of the host this device is paired with, if any.
  String? get connectedHostName => storage.getSetting('network.hostName');

  /// Pairs with a host on the local network and loads the models it shares.
  Future<void> connectToHost(Uri base, String pin, String hostName, String deviceName) async {
    final key = await pairWithHost(base, pin, deviceName);
    final settings = ProviderSettings(
      kind: ProviderKind.network,
      baseUrl: base.replace(path: '/v1').toString(),
      models: [],
    );
    providers[ProviderKind.network] = settings;
    await setKey(ProviderKind.network, key);
    await updateProviderSettings(settings);
    await storage.setSetting('network.hostName', hostName);
    try { await refreshHostModels(); }
    on LlmException catch (e) { if (e.statusCode != 403) rethrow; }
    if (settings.models.isNotEmpty) await selectModel(ProviderKind.network, settings.models.first);
  }

  Future<ToolOutput> _hostWeb(String tool, Map<String, dynamic> args) async {
    if (labRole != LabRole.client && labRole != LabRole.relay) return tools.builtin.call(tool, args);
    if (!hasKey(ProviderKind.network)) return const ToolOutput('Connect to Main and request web access first.', isError: true);
    final settings = providers[ProviderKind.network]!;
    final connection = ClientConnection(settings.baseUrl, keyFor(ProviderKind.network));
    try {
      final access = await connection.access();
      final port = access['mcpPort'] as int?;
      if (port == null) return const ToolOutput('MCP sharing is unavailable on Main.', isError: true);
      final uri = Uri.parse(settings.baseUrl).replace(port: port, path: '/mcp', query: '', fragment: '');
      final source = McpToolSource(ToolSourceConfig(id: 'main-web', type: ToolSourceType.mcp,
        name: 'Main web', url: uri.toString()), keyFor(ProviderKind.network));
      try { return await source.call(tool, args); } finally { await source.close(); }
    } finally { connection.close(); }
  }

  Set<String>? hostAllowedTools;
  void applyHostAccess(Map<String, dynamic> snapshot) {
    if (labRole == LabRole.relay && snapshot['serverTime'] is int) {
      host.server.relay?.clockOffset = Duration(milliseconds: (snapshot['serverTime'] as int) - DateTime.now().toUtc().millisecondsSinceEpoch);
    }
    final raw = (snapshot['access'] as Map?)?['tools'] as List?;
    final names = raw?.cast<String>().toSet();
    if (!setEquals(names, hostAllowedTools)) { hostAllowedTools = names; notifyListeners(); }
  }

  /// Refreshes the shared model list from the paired host.
  Future<void> refreshHostModels() async {
    final s = providers[ProviderKind.network]!;
    final provider = LlmProvider.create(s, keyFor(ProviderKind.network));
    try { s.models = await provider.listModels(); } finally { provider.client.close(); }
    await updateProviderSettings(s);
  }

  Future<void> disconnectHost() async {
    await setKey(ProviderKind.network, '');
    await updateProviderSettings(ProviderSettings(kind: ProviderKind.network, models: []));
    await storage.setSetting('network.hostName', null);
    if (provider == ProviderKind.network) {
      final fallback = ProviderKind.values.firstWhere(
          (k) => k != ProviderKind.network && k != ProviderKind.custom && hasKey(k),
          orElse: () => ProviderKind.anthropic);
      final models = providers[fallback]!.models;
      await selectModel(fallback, models.isEmpty ? '' : models.first);
    }
    notifyListeners();
  }

  Future<List<String>> fetchModels(ProviderKind k, {String? key}) {
    final p = _providerFactory(providers[k]!, key ?? keyFor(k));
    return p.listModels();
  }

  Future<void> selectModel(ProviderKind k, String m) async {
    if ((labRole == LabRole.client || labRole == LabRole.relay) && k != ProviderKind.network) return;
    provider = k;
    model = m;
    await storage.setSetting('provider', k.name);
    await storage.setSetting('model', m);
    notifyListeners();
  }

  Future<void> setLabRole(LabRole role) async {
    if (labRole != role) await host.stop();
    labRole = role;
    await storage.setSetting('lab.role', role.name);
    notifyListeners();
  }

  Future<void> setThemeStyle(AppThemeStyle style) async {
    themeStyle = style;
    await storage.setSetting('themeStyle', style.name);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    await storage.setSetting('theme', m.name);
    notifyListeners();
  }

  Future<void> setSystemPrompt(String v) async {
    systemPrompt = v;
    await storage.setSetting('systemPrompt', v);
    notifyListeners();
  }

  // Conversations

  void newChat() {
    if (isStreaming) stop();
    current = null;
    notifyListeners();
  }

  void open(Conversation c) {
    if (isStreaming) stop();
    storage.hydrate(c);
    current = c;
    notifyListeners();
  }

  Future<void> rename(Conversation c, String title) async {
    c.title = title.trim().isEmpty ? c.title : title.trim();
    await storage.saveConversation(c);
    notifyListeners();
  }

  /// Removes every conversation and its attachments.
  Future<void> deleteAllChats() async {
    if (isStreaming) stop();
    current = null;
    for (final c in List.of(conversations)) {
      await storage.deleteConversation(c);
    }
    conversations.clear();
    await storage.compactChats();
    notifyListeners();
  }

  Future<void> delete(Conversation c) async {
    if (current == c) newChat();
    conversations.remove(c);
    await storage.deleteConversation(c);
    notifyListeners();
  }

  // Chat

  Future<void> send(String text, List<Attachment> attachments) async {
    if (isStreaming) return;
    if (text.trim().isEmpty && attachments.isEmpty) return;
    var c = current;
    if (c == null) {
      c = Conversation(title: _titleFrom(text, attachments));
      current = c;
      conversations.insert(0, c);
    }
    c.messages.add(Message(role: Role.user, text: text.trim(), attachments: attachments));
    await _reply(c);
  }

  /// Re-runs the assistant reply after the last user message.
  Future<void> regenerate() async {
    final c = current;
    if (c == null || isStreaming) return;
    while (c.messages.isNotEmpty && c.messages.last.role != Role.user) {
      c.messages.removeLast();
    }
    if (c.messages.isEmpty) return;
    await _reply(c);
  }

  /// Replaces [m]'s text, drops everything after it and asks again.
  Future<void> editAndResend(Message m, String text) async {
    final c = current;
    if (c == null || isStreaming) return;
    final i = c.messages.indexOf(m);
    if (i < 0) return;
    c.messages.removeRange(i + 1, c.messages.length);
    m.text = text.trim();
    await _reply(c);
  }

  /// Most tool rounds per reply before the app stops the loop.
  static const maxToolRounds = 10;

  /// Answers the user, running tools the AI asks for until it is done.
  Future<void> _reply(Conversation c) async {
    _stopped = false;
    _bumpToTop(c);
    if (labRole == LabRole.client || labRole == LabRole.relay) {
      provider = ProviderKind.network;
      final models = providers[ProviderKind.network]!.models;
      if (!models.contains(model)) model = models.firstOrNull ?? '';
    }
    for (var round = 0;; round++) {
      final reply = Message(
          role: Role.assistant, model: model, provider: provider, usage: UsageStats());
      _clock = Stopwatch()..start();
      final history = List.of(c.messages);
      c.messages.add(reply);
      c.updatedAt = DateTime.now();
      streamingMessage = reply;
      notifyListeners();

      if ((labRole == LabRole.client || labRole == LabRole.relay) && (!hasKey(ProviderKind.network) || model.isEmpty)) {
        reply.error = 'Connect to Main and request access to a model first.';
        return _finish(c);
      }
      if (!hasKey(provider) && sources.forRoute(provider, model) == null && sources.chainFor(model) == null) {
        reply.error = provider == ProviderKind.local
            ? 'Download an on-device model in Settings first.'
            : 'Add a ${provider.label} API key in Settings to start chatting.';
        return _finish(c);
      }

      final offered = demoMode ? const <ToolSpec>[] : tools.activeTools().where((tool) =>
          (labRole != LabRole.client && labRole != LabRole.relay) || hostAllowedTools == null || hostAllowedTools!.contains(tool.name)).toList();
      await _stream(reply, history, offered);
      if (_stopped || reply.toolCalls.isEmpty) return _finish(c);
      if (round + 1 >= maxToolRounds) {
        reply.error = 'Stopped after $maxToolRounds rounds of tool use.';
        return _finish(c);
      }

      // Run the requested tools, then let the AI continue with the results.
      _closeTiming(reply);
      final results = <ToolResult>[];
      for (final call in reply.toolCalls) {
        if (_stopped) break;
        final spec = offered.where((t) => t.name == call.name).firstOrNull;
        if (spec == null) {
          results.add(ToolResult(callId: call.id, name: call.name,
              text: 'This tool was not offered or allowed for this chat.', isError: true));
          continue;
        }
        if (spec.needsApproval && !await _askApproval(call, spec)) {
          results.add(ToolResult(
              callId: call.id,
              name: call.name,
              text: 'The user declined to run this tool.',
              isError: true));
          continue;
        }
        streamingStatus = 'Running ${spec.sourceLabel}…';
        notifyListeners();
        results.add(await tools.execute(call, onProgress: (m) {
          streamingStatus = m;
          notifyListeners();
        }));
      }
      // Every call needs a result, even when the user pressed stop.
      for (final call in reply.toolCalls.skip(results.length)) {
        results.add(ToolResult(callId: call.id, name: call.name, text: 'Stopped by the user.', isError: true));
      }
      c.messages.add(Message(role: Role.tool, toolResults: results));
      streamingStatus = null;
      await storage.saveConversation(c);
      if (_stopped) return _finish(c);
    }
  }

  Future<void> _stream(
    Message reply,
    List<Message> history,
    List<ToolSpec> offered,
  ) async {
    final done = _done = Completer<void>();
    final selectedKind = provider;
    final selectedModel = model;
    final watch = Stopwatch()..start();
    LlmProvider? llm;
    try {
      llm = _activeProvider = providerFor(selectedKind, modelId: selectedModel);
      _sub = llm
          .streamChat(
            ChatRequest(
              model: selectedModel,
              messages: history,
              systemPrompt: systemPrompt,
              tools: offered,
            ),
          )
          .listen(
            (d) {
              streamingStatus = d.text.isEmpty && d.reasoning.isEmpty
                  ? d.status ?? streamingStatus
                  : null;
              if (d.usage != null) reply.usage!.merge(d.usage!);
              if ((d.text.isNotEmpty ||
                      d.reasoning.isNotEmpty ||
                      d.toolCalls.isNotEmpty) &&
                  reply.usage!.firstTokenMs == null) {
                reply.usage!.firstTokenMs = _clock?.elapsedMilliseconds;
              }
              reply.text += d.text;
              reply.reasoning += d.reasoning;
              reply.toolCalls.addAll(d.toolCalls);
              if (d.providerBlocks != null) {
                reply.providerBlocks = d.providerBlocks;
              }
              if (d.routingInfo != null) reply.routingInfo = d.routingInfo;
              if (d.notice != null) reply.error = d.notice;
              notifyListeners();
            },
            onError: (Object e) {
              reply.error = e is LlmException
                  ? e.message
                  : 'Connection failed: $e';
              if (!done.isCompleted) done.complete();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );
      await done.future;
    } catch (error) {
      reply.error = error is LlmException
          ? error.message
          : 'Connection failed: $error';
      if (!done.isCompleted) done.complete();
    } finally {
      llm?.client.close();
      if (_sub != null) await _sub!.cancel();
      _activeProvider = null;
      _sub = null;
      _done = null;
      _closeTiming(reply);
      if (!demoMode && selectedKind != ProviderKind.network) {
        try {
          await host.analytics.record(
            LabRequestEvent(
              deviceId: 'local',
              device: 'This PC',
              model: '${selectedKind.name}/$selectedModel',
              status: _stopped
                  ? 'cancelled'
                  : reply.error == null
                  ? 'ok'
                  : 'error',
              inputTokens: reply.usage?.inputTokens,
              outputTokens: reply.usage?.outputTokens,
              durationMs: watch.elapsedMilliseconds,
              firstTokenMs: reply.usage?.firstTokenMs,
            ),
          );
          await host.analytics.flush();
        } catch (_) {
          /* Reporting must not interrupt the chat. */
        }
      }
    }
  }

  void _closeTiming(Message reply) {
    if (reply.usage != null && _clock != null && reply.usage!.firstTokenMs != null) {
      reply.usage!.durationMs = _clock!.elapsedMilliseconds;
    }
  }

  /// A tool run waiting for the user's OK.
  ToolApprovalRequest? pendingApproval;

  Future<bool> _askApproval(ToolCall call, ToolSpec spec) async {
    final request = pendingApproval = ToolApprovalRequest(call, spec, tools.describe(call));
    streamingStatus = 'Waiting for your approval…';
    notifyListeners();
    final ok = await request._answer.future;
    pendingApproval = null;
    streamingStatus = null;
    notifyListeners();
    return ok;
  }

  /// Allows or denies the pending tool run.
  void answerApproval(bool allow) {
    final r = pendingApproval;
    if (r != null && !r._answer.isCompleted) r._answer.complete(allow);
  }

  Future<void> _finish(Conversation c) async {
    final reply = streamingMessage;
    if (reply != null) _closeTiming(reply);
    _clock = null;
    _sub = null;
    _done = null;
    streamingMessage = null;
    streamingStatus = null;
    c.updatedAt = DateTime.now();
    notifyListeners();
    await storage.saveConversation(c);
  }

  /// Cancels the reply in progress; whatever streamed so far is kept.
  void stop() {
    _stopped = true;
    answerApproval(false);
    _activeProvider?.client.close();
    _sub?.cancel();
    if (!(_done?.isCompleted ?? true)) _done!.complete();
  }

  void _bumpToTop(Conversation c) {
    conversations.remove(c);
    conversations.insert(0, c);
  }

  static String _titleFrom(String text, List<Attachment> attachments) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return attachments.isEmpty ? 'New chat' : attachments.first.name;
    return t.length <= 48 ? t : '${t.substring(0, 45)}…';
  }
}

/// Exposes [AppState] to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/// A tool run that needs the user's OK.
class ToolApprovalRequest {
  ToolApprovalRequest(this.call, this.spec, this.preview);

  final ToolCall call;
  final ToolSpec spec;

  /// What will run: the command line for CLI tools, else the arguments.
  final String preview;
  final Completer<bool> _answer = Completer<bool>();
}

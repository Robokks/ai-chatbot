import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/storage.dart';
import '../data/llm/demo_provider.dart';
import '../data/llm/llm_provider.dart';
import '../data/models.dart';

const demoMode = bool.fromEnvironment('DEMO');

/// App-wide state: settings, provider keys, conversations and the active
/// streaming reply.
class AppState extends ChangeNotifier {
  AppState(this.storage, {LlmProvider Function(ProviderSettings, String)? providerFactory})
      : _providerFactory = providerFactory ??
            ((s, k) => demoMode ? DemoProvider(s) : LlmProvider.create(s, k));

  final Storage storage;
  final LlmProvider Function(ProviderSettings, String) _providerFactory;

  final Map<ProviderKind, ProviderSettings> providers = {};
  final Map<ProviderKind, String> _keys = {};
  List<Conversation> conversations = [];
  Conversation? current;

  ThemeMode themeMode = ThemeMode.system;
  String systemPrompt = '';
  ProviderKind provider = ProviderKind.anthropic;
  String model = ProviderKind.anthropic.models.first;

  StreamSubscription<ChatDelta>? _sub;
  Completer<void>? _done;
  Message? streamingMessage;
  bool get isStreaming => streamingMessage != null;

  Future<void> load() async {
    for (final k in ProviderKind.values) {
      providers[k] = storage.providerSettings(k);
      final key = await storage.readKey(k);
      if (key != null && key.isNotEmpty) _keys[k] = key;
    }
    themeMode = ThemeMode.values.asNameMap()[storage.getSetting('theme')] ??
        ThemeMode.system;
    systemPrompt = storage.getSetting('systemPrompt') ?? '';
    provider = ProviderKind.values.asNameMap()[storage.getSetting('provider')] ??
        ProviderKind.anthropic;
    model = storage.getSetting('model') ?? providers[provider]!.models.first;
    conversations = storage.loadConversations();
    notifyListeners();
  }

  // Settings

  bool hasKey(ProviderKind k) =>
      demoMode || k == ProviderKind.custom || (_keys[k]?.isNotEmpty ?? false);
  String keyFor(ProviderKind k) => _keys[k] ?? '';

  /// Providers the user can chat with right now.
  List<ProviderKind> get readyProviders =>
      ProviderKind.values.where((k) => _keys.containsKey(k) || demoMode).toList();

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

  Future<List<String>> fetchModels(ProviderKind k, {String? key}) {
    final p = _providerFactory(providers[k]!, key ?? keyFor(k));
    return p.listModels();
  }

  Future<void> selectModel(ProviderKind k, String m) async {
    provider = k;
    model = m;
    await storage.setSetting('provider', k.name);
    await storage.setSetting('model', m);
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
    while (c.messages.isNotEmpty && c.messages.last.role == Role.assistant) {
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

  Future<void> _reply(Conversation c) async {
    final history = List.of(c.messages);
    final reply = Message(role: Role.assistant, model: model);
    c.messages.add(reply);
    c.updatedAt = DateTime.now();
    _bumpToTop(c);
    streamingMessage = reply;
    notifyListeners();

    if (!hasKey(provider)) {
      reply.error = 'Add a ${provider.label} API key in Settings to start chatting.';
      await _finish(c);
      return;
    }

    final llm = _providerFactory(providers[provider]!, keyFor(provider));
    final done = _done = Completer<void>();
    _sub = llm
        .streamChat(ChatRequest(
          model: model,
          messages: history,
          systemPrompt: systemPrompt,
        ))
        .listen(
          (d) {
            reply.text += d.text;
            reply.reasoning += d.reasoning;
            if (d.notice != null) reply.error = d.notice;
            notifyListeners();
          },
          onError: (Object e) {
            reply.error = e is LlmException ? e.message : 'Connection failed: $e';
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    await done.future;
    await _finish(c);
  }

  Future<void> _finish(Conversation c) async {
    _sub = null;
    _done = null;
    streamingMessage = null;
    c.updatedAt = DateTime.now();
    notifyListeners();
    await storage.saveConversation(c);
  }

  /// Cancels the reply in progress; whatever streamed so far is kept.
  void stop() {
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

import 'dart:async';

import 'package:llamadart/llamadart.dart';

import '../models.dart';
import 'llm_provider.dart';

/// Keeps one llama.cpp model loaded; loading takes seconds, so it is reused
/// across messages and only swapped when another model is picked.
class LocalEngineHost {
  LocalEngineHost._();
  static final instance = LocalEngineHost._();

  static const contextSize = 4096;

  LlamaEngine? _engine;
  String? _path;
  Future<LlamaEngine>? _loading;

  bool isLoaded(String path) => _engine != null && _path == path;

  Future<LlamaEngine> engineFor(String path) async {
    if (_engine != null && _path == path) return _engine!;
    if (_loading != null && _path == path) return _loading!;
    await unload();
    _path = path;
    final loading = _loading = LlamaEngine.load(
      LlamaModel(ModelSource.path(path)),
      params: const ModelParams(contextSize: contextSize),
    );
    try {
      _engine = await loading;
      return _engine!;
    } catch (_) {
      _path = null;
      rethrow;
    } finally {
      _loading = null;
    }
  }

  void cancel() => _engine?.cancelGeneration();

  Future<void> unload() async {
    final e = _engine;
    _engine = null;
    _path = null;
    await e?.dispose();
  }

  /// Unloads [path] if it is the loaded model (before deleting the file).
  Future<void> release(String path) async {
    if (_path == path) await unload();
  }
}

/// Chat with a GGUF model on this device through llama.cpp.
class LocalProvider extends LlmProvider {
  LocalProvider({
    required super.settings,
    required this.pathFor,
    LocalEngineHost? host,
  })  : host = host ?? LocalEngineHost.instance,
        super(apiKey: '');

  /// Resolves a model id to its .gguf file.
  final Future<String> Function(String modelId) pathFor;
  final LocalEngineHost host;

  /// Rough character budget for history so prompts fit the context window
  /// (about 3.5 characters per token, leaving room for the reply).
  static const historyCharBudget = 7000;

  /// Converts the conversation to llama.cpp chat messages, keeping the most
  /// recent turns that fit [historyCharBudget].
  static List<LlamaChatMessage> toLlamaMessages(ChatRequest req) {
    final turns = <LlamaChatMessage>[];
    var used = 0;
    for (final m in req.messages.reversed) {
      final text = m.role == Role.user
          ? inlineTextAttachments(m, includePdf: true)
          : m.text;
      if (text.isEmpty) continue;
      if (turns.isNotEmpty && used + text.length > historyCharBudget) break;
      used += text.length;
      turns.insert(
        0,
        LlamaChatMessage.fromText(
          role: m.role == Role.user ? LlamaChatRole.user : LlamaChatRole.assistant,
          text: text,
        ),
      );
    }
    // A history must start with the user.
    while (turns.isNotEmpty && turns.first.role == LlamaChatRole.assistant) {
      turns.removeAt(0);
    }
    final system = req.systemPrompt?.trim() ?? '';
    return [
      if (system.isNotEmpty)
        LlamaChatMessage.fromText(role: LlamaChatRole.system, text: system),
      ...turns,
    ];
  }

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) {
    StreamSubscription<LlamaCompletionChunk>? sub;
    late final StreamController<ChatDelta> out;
    out = StreamController<ChatDelta>(
      onListen: () async {
        try {
          final path = await pathFor(request.model);
          if (!host.isLoaded(path)) {
            out.add(const ChatDelta(status: 'Loading model…'));
          }
          final engine = await host.engineFor(path);
          if (out.isClosed) return;
          sub = engine
              .create(
                toLlamaMessages(request),
                params: const GenerationParams(maxTokens: 2048),
              )
              .listen(
            (chunk) {
              if (chunk.choices.isEmpty) return;
              final d = chunk.choices.first.delta;
              final text = d.content ?? '';
              final thinking = d.thinking ?? '';
              if (text.isNotEmpty || thinking.isNotEmpty) {
                out.add(ChatDelta(text: text, reasoning: thinking));
              }
            },
            onError: (Object e) {
              out.addError(LlmException('The on-device model stopped: $e'));
              out.close();
            },
            onDone: out.close,
          );
        } catch (e) {
          out.addError(LlmException('Could not load the model: $e'));
          await out.close();
        }
      },
      onCancel: () async {
        host.cancel();
        await sub?.cancel();
      },
    );
    return out.stream;
  }

  @override
  Future<List<String>> listModels() async => settings.models;
}

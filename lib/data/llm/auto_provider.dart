import 'dart:async';
import 'dart:convert';

import '../models.dart';
import 'llm_provider.dart';

/// One provider and model Free Auto may use.
class AutoRoute {
  AutoRoute({required this.kind, required this.model, this.enabled = true});

  final ProviderKind kind;
  String model;
  bool enabled;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'model': model, 'on': enabled};

  static AutoRoute? fromJson(Map<String, dynamic> j) {
    final k = ProviderKind.values.asNameMap()[j['kind']];
    if (k == null || !k.free) return null;
    return AutoRoute(kind: k, model: j['model'] as String? ?? '', enabled: j['on'] as bool? ?? true);
  }
}

/// The order Free Auto tries free providers in, before the user changes it.
const defaultAutoOrder = [
  ProviderKind.gemini,
  ProviderKind.groq,
  ProviderKind.cerebras,
  ProviderKind.mistral,
  ProviderKind.openrouter,
  ProviderKind.github,
  ProviderKind.nvidia,
  ProviderKind.huggingface,
  ProviderKind.cloudflare,
  ProviderKind.cohere,
  ProviderKind.sambanova,
  ProviderKind.zai,
  ProviderKind.freellmapi,
];

/// The model Free Auto uses for [kind] when the user hasn't picked one:
/// for OpenRouter only a ":free" model, else the provider's first model.
String? defaultAutoModel(ProviderKind kind, List<String> models) {
  if (kind == ProviderKind.openrouter) {
    for (final m in models) {
      if (m.endsWith(':free')) return m;
    }
    return null;
  }
  return models.isEmpty ? null : models.first;
}

/// Merges saved routes with the providers that now have keys: saved order
/// first, then new providers in [defaultAutoOrder]. Routes without a usable
/// model are left out.
List<AutoRoute> resolveAutoRoutes(
  String? saved, {
  required bool Function(ProviderKind) hasKey,
  required List<String> Function(ProviderKind) modelsFor,
}) {
  final out = <AutoRoute>[];
  if (saved != null) {
    try {
      for (final e in jsonDecode(saved) as List) {
        final r = AutoRoute.fromJson(Map<String, dynamic>.from(e as Map));
        if (r != null && !out.any((x) => x.kind == r.kind)) out.add(r);
      }
    } catch (_) {
      // Damaged setting: start from the default order.
    }
  }
  for (final k in defaultAutoOrder) {
    if (out.any((r) => r.kind == k)) continue;
    final m = defaultAutoModel(k, modelsFor(k));
    if (m != null) out.add(AutoRoute(kind: k, model: m));
  }
  return [
    for (final r in out)
      if (hasKey(r.kind) &&
          (r.model.isNotEmpty || defaultAutoModel(r.kind, modelsFor(r.kind)) != null))
        r..model = r.model.isNotEmpty ? r.model : defaultAutoModel(r.kind, modelsFor(r.kind))!,
  ];
}

String encodeAutoRoutes(List<AutoRoute> routes) => jsonEncode([for (final r in routes) r.toJson()]);

/// Remembers which providers hit their limit, app-wide.
class AutoCooldowns {
  final Map<ProviderKind, DateTime> _until = {};

  /// Last provider and model that answered.
  (ProviderKind, String)? lastUsed;

  DateTime? until(ProviderKind k) {
    final t = _until[k];
    if (t != null && DateTime.now().isAfter(t)) _until.remove(k);
    return _until[k];
  }

  void rest(ProviderKind k, Duration d) => _until[k] = DateTime.now().add(d);
  void clear(ProviderKind k) => _until.remove(k);
}

/// "Free Auto": answers with the first free provider that works, and moves
/// on to the next one when a provider is at its limit or fails before it
/// starts answering. An answer is never mixed from two models.
class AutoProvider extends LlmProvider {
  AutoProvider({
    required super.settings,
    required this.routes,
    required this.providerFor,
    required this.cooldowns,
    this.limitRest = const Duration(minutes: 15),
    this.keyRest = const Duration(hours: 1),
  }) : super(apiKey: '');

  final List<AutoRoute> routes;
  final LlmProvider Function(ProviderKind) providerFor;
  final AutoCooldowns cooldowns;
  final Duration limitRest;
  final Duration keyRest;

  /// Whether a request with pictures should go straight to a provider that
  /// can see them (they are read into text otherwise).
  static bool _hasImages(ChatRequest r) => r.messages.any((m) => m.attachments
      .any((a) => a.kind == AttachmentKind.image && a.bytes != null && a.text == null));

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    final usable = [
      for (final r in routes)
        if (r.enabled) r,
    ];
    if (usable.isEmpty) {
      throw LlmException('Free Auto has no free providers yet. Add a free key in Settings → '
          'API keys (for example Groq, Cerebras or Gemini).');
    }
    final available = [for (final r in usable) if (cooldowns.until(r.kind) == null) r];
    // Everyone is resting: try the one that rests the shortest.
    if (available.isEmpty) {
      usable.sort((a, b) => cooldowns.until(a.kind)!.compareTo(cooldowns.until(b.kind)!));
      available.add(usable.first);
    }
    if (_hasImages(request)) {
      available.sort((a, b) => (b.kind.images ? 1 : 0) - (a.kind.images ? 1 : 0));
    }

    final problems = <String>[];
    for (final route in available) {
      final p = providerFor(route.kind);
      var started = false;
      try {
        if (problems.isNotEmpty) yield ChatDelta(status: 'Trying ${route.kind.label}…');
        await for (final d in p.streamChat(ChatRequest(
          model: route.model,
          messages: request.messages,
          systemPrompt: request.systemPrompt,
          tools: request.tools,
        ))) {
          if (!started &&
              (d.text.isNotEmpty || d.reasoning.isNotEmpty || d.toolCalls.isNotEmpty)) {
            started = true;
            cooldowns.lastUsed = (route.kind, route.model);
            yield ChatDelta(servedBy: (route.kind, route.model));
          }
          yield d;
        }
        if (!started) {
          // An empty answer still counts as an answer.
          cooldowns.lastUsed = (route.kind, route.model);
          yield ChatDelta(servedBy: (route.kind, route.model));
        }
        return;
      } catch (e) {
        if (started) rethrow;
        final status = e is LlmException ? e.statusCode : null;
        if (status == 429) {
          cooldowns.rest(route.kind, limitRest);
          problems.add('${route.kind.label}: limit reached');
        } else if (status == 401 || status == 403) {
          cooldowns.rest(route.kind, keyRest);
          problems.add('${route.kind.label}: key not accepted');
        } else {
          problems.add('${route.kind.label}: ${e is LlmException ? e.message : e}');
        }
      }
    }
    throw LlmException('All free providers failed right now. ${problems.join(' · ')}');
  }

  @override
  Future<List<String>> listModels() async => const ['auto'];
}

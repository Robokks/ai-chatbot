import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../core/storage.dart';
import '../models.dart';
import 'llm_provider.dart';

class NamedSource {
  NamedSource({required this.id, required this.name, required this.url,
    this.kind = ProviderKind.custom, List<String>? models, this.enabled = true, this.shared = false})
      : models = models ?? [];
  final String id;
  String name;
  String url;
  final ProviderKind kind;
  List<String> models;
  bool enabled;
  bool shared;
  String route(String model) => 'source:$id::$model';
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'kind': kind.name,
    'models': models, 'enabled': enabled, 'shared': shared};
  factory NamedSource.fromJson(Map<String, dynamic> j) => NamedSource(id: j['id'] as String,
    name: j['name'] as String, url: j['url'] as String,
    kind: ProviderKind.values.byName(j['kind'] as String? ?? 'custom'),
    models: (j['models'] as List).cast<String>(), enabled: j['enabled'] as bool? ?? true,
    shared: j['shared'] as bool? ?? false);
}

/// Public source metadata and encrypted credentials are saved separately.
class NamedSources extends ChangeNotifier {
  NamedSources(this.storage, {LlmProvider Function(ProviderSettings, String)? factory})
      : factory = factory ?? ((s, key) => LlmProvider.create(s, key));
  final Storage storage;
  final LlmProvider Function(ProviderSettings, String) factory;
  final List<NamedSource> all = [];
  final Map<String, List<String>> _keys = {};
  final Map<String, String> health = {};

  Future<void> load() async {
    final raw = storage.getSetting('lab.sources');
    all.clear(); _keys.clear();
    if (raw != null) {
      all.addAll((jsonDecode(raw) as List).map((j) => NamedSource.fromJson(Map<String, dynamic>.from(j))));
      for (final source in all) {
        final saved = await storage.readSecret('lab.source.${source.id}.keys');
        _keys[source.id] = saved == null ? [] : (jsonDecode(saved) as List).cast<String>();
      }
    }
  }
  static void validate(NamedSource source) {
    final uri = Uri.tryParse(source.url);
    if (source.name.trim().isEmpty || source.id.isEmpty || source.id.contains('::') ||
        source.kind == ProviderKind.local || source.kind == ProviderKind.network || uri == null ||
        !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment) {
      throw const FormatException('Enter a name and an http(s) API base URL without embedded credentials.');
    }
    if (source.models.any((m) => m.trim().isEmpty)) throw const FormatException('Model names cannot be empty.');
  }
  Future<void> save(NamedSource source, {List<String>? keys}) async {
    validate(source);
    if (keys != null) {
      final cleaned = keys.map((k) => k.trim()).where((k) => k.isNotEmpty).toSet().toList();
      await storage.writeSecret('lab.source.${source.id}.keys', jsonEncode(cleaned));
      _keys[source.id] = cleaned;
    }
    final index = all.indexWhere((s) => s.id == source.id);
    if (index == -1) { all.add(source); } else { all[index] = source; }
    await storage.setSetting('lab.sources', jsonEncode(all.map((s) => s.toJson()).toList()));
    notifyListeners();
  }
  Future<void> remove(NamedSource source) async {
    all.removeWhere((s) => s.id == source.id); _keys.remove(source.id); health.remove(source.id);
    await storage.setSetting('lab.sources', jsonEncode(all.map((s) => s.toJson()).toList()));
    await storage.writeSecret('lab.source.${source.id}.keys', null);
    notifyListeners();
  }
  int keyCount(NamedSource source) => _keys[source.id]?.length ?? 0;
  Future<void> check(NamedSource source) async {
    final provider = factory(ProviderSettings(kind: source.kind, baseUrl: source.url), _keys[source.id]?.firstOrNull ?? '');
    try {
      final models = await provider.listModels().timeout(const Duration(seconds: 15));
      source.models = models.toSet().toList()..sort();
      health[source.id] = 'Healthy · ${source.models.length} models';
      await save(source);
    } catch (_) {
      health[source.id] = 'Could not connect. Check the URL, key and network.';
      notifyListeners();
      rethrow;
    } finally { provider.client.close(); }
  }
  NamedSource? forRoute(ProviderKind kind, String route) {
    if (!route.startsWith('source:')) return null;
    final split = route.indexOf('::');
    if (split <= 7) return null;
    return all.where((s) => s.kind == kind && s.id == route.substring(7, split)).firstOrNull;
  }
  LlmProvider provider(NamedSource source, String route) {
    if (!source.enabled) throw LlmException('This source is disabled.');
    final model = route.substring(source.route('').length);
    if (!source.models.contains(model)) throw LlmException('This model is not available from the source.');
    final delegate = factory(ProviderSettings(kind: source.kind, baseUrl: source.url, models: source.models),
      _keys[source.id]?.firstOrNull ?? '');
    return _NamedProvider(delegate, model);
  }
}
class _NamedProvider extends LlmProvider {
  _NamedProvider(this.delegate, this.model) : super(settings: delegate.settings, apiKey: delegate.apiKey, client: delegate.client);
  final LlmProvider delegate;
  final String model;
  @override Stream<ChatDelta> streamChat(ChatRequest request) => delegate.streamChat(ChatRequest(
    model: model, messages: request.messages, systemPrompt: request.systemPrompt,
    tools: request.tools, maxOutputTokens: request.maxOutputTokens));
  @override Future<List<String>> listModels() => delegate.listModels();
}

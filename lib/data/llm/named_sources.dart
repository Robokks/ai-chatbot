import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../../core/storage.dart';
import '../models.dart';
import 'llm_provider.dart';

class NamedSource {
  NamedSource({
    required this.id,
    required this.name,
    required this.url,
    this.kind = ProviderKind.custom,
    List<String>? models,
    this.enabled = true,
    this.shared = false,
    this.requestUsage = true,
  }) : models = models ?? [];
  final String id;
  String name;
  String url;
  final ProviderKind kind;
  List<String> models;
  bool enabled;
  bool shared;
  bool requestUsage;
  String route(String model) => 'source:$id::$model';
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'kind': kind.name,
    'models': models,
    'enabled': enabled,
    'shared': shared,
    'requestUsage': requestUsage,
  };
  factory NamedSource.fromJson(Map<String, dynamic> j) => NamedSource(
    id: j['id'] as String,
    name: j['name'] as String,
    url: j['url'] as String,
    kind: ProviderKind.values.byName(j['kind'] as String? ?? 'custom'),
    models: (j['models'] as List).cast<String>(),
    enabled: j['enabled'] as bool? ?? true,
    shared: j['shared'] as bool? ?? false,
    requestUsage: j['requestUsage'] as bool? ?? true,
  );
}

/// Public source metadata and encrypted credentials are saved separately.
class NamedSources extends ChangeNotifier {
  NamedSources(
    this.storage, {
    LlmProvider Function(ProviderSettings, String)? factory,
  }) : factory = factory ?? ((s, key) => LlmProvider.create(s, key));
  final Storage storage;
  final LlmProvider Function(ProviderSettings, String) factory;
  final List<NamedSource> all = [];
  final Map<String, List<String>> _keys = {};
  final Map<String, String> health = {};
  final List<RoutingChain> chains = [];
  final Map<String, RouteHealth> metrics = {};
  final Map<String, int> _nextKey = {};
  final Map<String, RouteHealth> keyUsage = {};
  String keySummary(NamedSource source) => [
    for (var i = 0; i < keyCount(source); i++)
      'Key ${i + 1}: ${keyUsage['${source.id}:$i']?.successes ?? 0} completed · ${(keyUsage['${source.id}:$i']?.inputTokens ?? 0) + (keyUsage['${source.id}:$i']?.outputTokens ?? 0)} reported tokens${(_cooldown['${source.id}:$i']?.isAfter(DateTime.now()) ?? false) ? " · cooling down" : ""}',
  ].join('\n');
  final Map<String, DateTime> _cooldown = {};
  Duration firstOutputTimeout = const Duration(seconds: 15);

  ProviderKind kindForChain(RoutingChain chain) =>
      all
          .where((s) => chain.routes.any((r) => r.startsWith(s.route(''))))
          .firstOrNull
          ?.kind ??
      ProviderKind.custom;
  RoutingChain? chainFor(String route) =>
      chains.where((c) => c.route == route).firstOrNull;
  Future<void> saveChain(RoutingChain chain) async {
    if (chain.name.trim().isEmpty || chain.id.isEmpty || chain.routes.isEmpty) {
      throw const FormatException(
        'Name the chain and select at least one model.',
      );
    }
    final sources = chain.routes
        .map(
          (r) => all
              .where(
                (s) =>
                    r.startsWith(s.route('')) &&
                    s.models.contains(r.substring(s.route('').length)),
              )
              .firstOrNull,
        )
        .toList();
    if (sources.any((s) => s == null) ||
        sources.map((s) => s!.kind).toSet().length != 1) {
      throw const FormatException(
        'Choose models using the same API format to preserve tool history.',
      );
    }
    chains.removeWhere((c) => c.id == chain.id);
    chains.add(chain);
    await _saveRouting();
  }

  Future<void> removeChain(RoutingChain chain) async {
    chains.removeWhere((c) => c.id == chain.id);
    await _saveRouting();
  }

  Future<void> _saveRouting() async {
    await storage.setSetting(
      'lab.routing',
      jsonEncode({
        'chains': chains.map((c) => c.toJson()).toList(),
        'metrics': metrics.map((k, v) => MapEntry(k, v.toJson())),
        'keys': keyUsage.map((k, v) => MapEntry(k, v.toJson())),
        'cooldown': _cooldown.map((k, v) => MapEntry(k, v.toIso8601String())),
      }),
    );
    notifyListeners();
  }

  LlmProvider routingProvider(String route) {
    final chain = chainFor(route);
    if (chain == null || !chain.enabled) {
      throw LlmException('This routing chain is unavailable.');
    }
    final candidates = chain.routes
        .where(
          (r) => all.any(
            (s) =>
                s.enabled &&
                r.startsWith(s.route('')) &&
                s.models.contains(r.substring(s.route('').length)),
          ),
        )
        .toList();
    if (chain.strategy != RoutingStrategy.manual) {
      candidates.sort((a, b) {
        final x = metrics[a] ?? RouteHealth(), y = metrics[b] ?? RouteHealth();
        return switch (chain.strategy) {
          RoutingStrategy.reliable => y.reliability.compareTo(x.reliability),
          RoutingStrategy.fastest => (x.firstMs ?? double.infinity).compareTo(
            y.firstMs ?? double.infinity,
          ),
          RoutingStrategy.smartest => (chain.priorities[b] ?? 0).compareTo(
            chain.priorities[a] ?? 0,
          ),
          RoutingStrategy.manual => 0,
        };
      });
    }
    return _RoutingProvider(this, candidates);
  }

  Future<void> load() async {
    final raw = storage.getSetting('lab.sources');
    all.clear();
    _keys.clear();
    final routing = storage.getSetting('lab.routing');
    chains.clear();
    metrics.clear();
    keyUsage.clear();
    _cooldown.clear();
    if (routing != null) {
      final data = jsonDecode(routing) as Map;
      chains.addAll(
        (data['chains'] as List).map(
          (j) => RoutingChain.fromJson(Map<String, dynamic>.from(j)),
        ),
      );
      (data['keys'] as Map? ?? {}).forEach(
        (k, v) => keyUsage[k as String] = RouteHealth.fromJson(
          Map<String, dynamic>.from(v),
        ),
      );
      (data['cooldown'] as Map? ?? {}).forEach(
        (k, v) => _cooldown[k as String] = DateTime.parse(v),
      );
      (data['metrics'] as Map).forEach(
        (k, v) => metrics[k as String] = RouteHealth.fromJson(
          Map<String, dynamic>.from(v),
        ),
      );
    }
    if (raw != null) {
      all.addAll(
        (jsonDecode(raw) as List).map(
          (j) => NamedSource.fromJson(Map<String, dynamic>.from(j)),
        ),
      );
      for (final source in all) {
        final saved = await storage.readSecret('lab.source.${source.id}.keys');
        _keys[source.id] = saved == null
            ? []
            : (jsonDecode(saved) as List).cast<String>();
      }
    }
  }

  static void validate(NamedSource source) {
    final uri = Uri.tryParse(source.url);
    if (source.name.trim().isEmpty ||
        source.id.isEmpty ||
        source.id.contains('::') ||
        source.kind == ProviderKind.local ||
        source.kind == ProviderKind.network ||
        uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Enter a name and an http(s) API base URL without embedded credentials.',
      );
    }
    if (source.models.any((m) => m.trim().isEmpty)) {
      throw const FormatException('Model names cannot be empty.');
    }
  }

  Future<void> save(NamedSource source, {List<String>? keys}) async {
    validate(source);
    if (keys != null) {
      final cleaned = keys
          .map((k) => k.trim())
          .where((k) => k.isNotEmpty)
          .toSet()
          .toList();
      await storage.writeSecret(
        'lab.source.${source.id}.keys',
        jsonEncode(cleaned),
      );
      if (!listEquals(_keys[source.id], cleaned)) {
        _nextKey.remove(source.id);
        keyUsage.removeWhere((id, _) => id.startsWith('${source.id}:'));
        _cooldown.removeWhere((id, _) => id.startsWith('${source.id}:'));
      }
      _keys[source.id] = cleaned;
    }
    final index = all.indexWhere((s) => s.id == source.id);
    if (index == -1) {
      all.add(source);
    } else {
      all[index] = source;
    }
    await storage.setSetting(
      'lab.sources',
      jsonEncode(all.map((s) => s.toJson()).toList()),
    );
    if (keys != null) await _saveRouting();
    notifyListeners();
  }

  Future<void> remove(NamedSource source) async {
    all.removeWhere((s) => s.id == source.id);
    _keys.remove(source.id);
    health.remove(source.id);
    await storage.setSetting(
      'lab.sources',
      jsonEncode(all.map((s) => s.toJson()).toList()),
    );
    await storage.writeSecret('lab.source.${source.id}.keys', null);
    notifyListeners();
  }

  int keyCount(NamedSource source) => _keys[source.id]?.length ?? 0;
  Future<void> check(NamedSource source) async {
    final provider = factory(
      ProviderSettings(kind: source.kind, baseUrl: source.url),
      _keys[source.id]?.firstOrNull ?? '',
    );
    try {
      final models = await provider.listModels().timeout(
        const Duration(seconds: 15),
      );
      source.models = models.toSet().toList()..sort();
      health[source.id] = 'Healthy · ${source.models.length} models';
      await save(source);
    } catch (_) {
      health[source.id] = 'Could not connect. Check the URL, key and network.';
      notifyListeners();
      rethrow;
    } finally {
      provider.client.close();
    }
  }

  NamedSource? forRoute(ProviderKind kind, String route) {
    if (!route.startsWith('source:')) return null;
    final split = route.indexOf('::');
    if (split <= 7) return null;
    return all
        .where((s) => s.kind == kind && s.id == route.substring(7, split))
        .firstOrNull;
  }

  LlmProvider provider(NamedSource source, String route) {
    if (!source.enabled) throw LlmException('This source is disabled.');
    final model = route.substring(source.route('').length);
    if (!source.models.contains(model)) {
      throw LlmException('This model is not available from the source.');
    }
    return _RoutingProvider(this, [route]);
  }
}

enum RoutingStrategy { manual, fastest, reliable, smartest }

class RoutingChain {
  RoutingChain({
    required this.id,
    required this.name,
    required this.routes,
    this.strategy = RoutingStrategy.manual,
    this.enabled = true,
    this.shared = false,
    Map<String, int>? priorities,
  }) : priorities = priorities ?? {};
  final String id;
  String name;
  List<String> routes;
  RoutingStrategy strategy;
  bool enabled, shared;
  Map<String, int> priorities;
  String get route => 'auto:$id';
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'routes': routes,
    'strategy': strategy.name,
    'enabled': enabled,
    'shared': shared,
    'priorities': priorities,
  };
  factory RoutingChain.fromJson(Map<String, dynamic> j) => RoutingChain(
    id: j['id'],
    name: j['name'],
    routes: (j['routes'] as List).cast<String>(),
    strategy: RoutingStrategy.values.byName(j['strategy']),
    enabled: j['enabled'] ?? true,
    shared: j['shared'] ?? false,
    priorities: Map<String, int>.from(j['priorities'] ?? {}),
  );
}

class RouteHealth {
  int successes = 0, failures = 0, inputTokens = 0, outputTokens = 0;
  double? firstMs;
  double get reliability =>
      successes + failures == 0 ? 0.5 : successes / (successes + failures);
  Map<String, dynamic> toJson() => {
    'successes': successes,
    'failures': failures,
    'input': inputTokens,
    'output': outputTokens,
    'firstMs': firstMs,
  };
  factory RouteHealth.fromJson(Map<String, dynamic> j) => RouteHealth()
    ..successes = j['successes'] ?? 0
    ..failures = j['failures'] ?? 0
    ..inputTokens = j['input'] ?? 0
    ..outputTokens = j['output'] ?? 0
    ..firstMs = (j['firstMs'] as num?)?.toDouble();
  RouteHealth();
}

// Closing the outward provider also closes the active request and disables retries.
class _RoutingClient extends http.BaseClient {
  http.Client? active;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => Future.error(
    StateError('Routing client does not send requests directly.'),
  );
  @override
  void close() {
    closed = true;
    active?.close();
  }
}

class _RoutingProvider extends LlmProvider {
  _RoutingProvider(this.catalog, this.routes)
    : super(
        settings: ProviderSettings(kind: catalog.all.where((s) => routes.any((r) => r.startsWith(s.route('')))).firstOrNull?.kind ?? ProviderKind.custom),
        apiKey: '',
        client: _RoutingClient(),
      );
  final NamedSources catalog;
  final List<String> routes;
  _RoutingClient get transport => client as _RoutingClient;
  @override
  Future<List<String>> listModels() async => routes;
  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    Object? last;
    var fallbacks = 0;
    for (final route in routes) {
      final source = catalog.all
          .where((s) => route.startsWith(s.route('')))
          .first;
      final keys = catalog._keys[source.id] ?? [''];
      final available = keys.isEmpty ? [''] : keys;
      final start = catalog._nextKey[source.id] ?? 0;
      for (var attempt = 0; attempt < available.length; attempt++) {
        if (transport.closed) return;
        final index = (start + attempt) % available.length;
        final keyId = '${source.id}:$index';
        if (catalog._cooldown[keyId]?.isAfter(DateTime.now()) ?? false) {
          continue;
        }
        catalog._nextKey[source.id] = (index + 1) % available.length;
        final delegate = catalog.factory(
          ProviderSettings(
            kind: source.kind,
            baseUrl: source.url,
            models: source.models,
            requestUsage: source.requestUsage,
          ),
          available[index],
        );
        transport.active = delegate.client;
        final stats = catalog.metrics.putIfAbsent(route, RouteHealth.new);
        final keyStats = catalog.keyUsage.putIfAbsent(keyId, RouteHealth.new);
        final watch = Stopwatch()..start();
        var emitted = false;
        final usage = UsageStats();
        final iterator = StreamIterator(
          delegate.streamChat(
            ChatRequest(
              model: route.substring(source.route('').length),
              messages: request.messages,
              systemPrompt: request.systemPrompt,
              tools: request.tools,
              maxOutputTokens: request.maxOutputTokens,
            ),
          ),
        );
        try {
          while (await (emitted
              ? iterator.moveNext()
              : iterator.moveNext().timeout(
                  catalog.firstOutputTimeout - watch.elapsed > Duration.zero
                      ? catalog.firstOutputTimeout - watch.elapsed
                      : Duration.zero,
                ))) {
            if (transport.closed) return;
            final delta = iterator.current;
            if (!emitted &&
                (delta.text.isNotEmpty ||
                    delta.reasoning.isNotEmpty ||
                    delta.toolCalls.isNotEmpty ||
                    delta.providerBlocks != null ||
                    (delta.notice?.isNotEmpty ?? false))) {
              emitted = true;
              stats.firstMs = stats.firstMs == null
                  ? watch.elapsedMilliseconds.toDouble()
                  : (stats.firstMs! * 0.75 + watch.elapsedMilliseconds * 0.25);
              yield ChatDelta(
                routingInfo:
                    'Answered by ${source.name} · ${route.substring(source.route('').length)} · $fallbacks fallbacks',
              );
            }
            if (delta.usage != null) {
              usage.merge(delta.usage!);
            }
            yield delta;
          }
          if (!emitted) throw LlmException('The model returned no output.');
          stats.successes++;
          keyStats.successes++;
          await catalog._saveRouting();
          return;
        } catch (error) {
          if (transport.closed) return;
          stats.failures++;
          keyStats.failures++;
          last = error;
          if (error is LlmException &&
              [401, 403, 429].contains(error.statusCode)) {
            catalog._cooldown[keyId] = DateTime.now().add(
              Duration(seconds: error.statusCode == 429 ? 60 : 300),
            );
          }
          await catalog._saveRouting();
          if (emitted) rethrow;
          fallbacks++;
        } finally {
          stats.inputTokens += usage.inputTokens ?? 0;
          stats.outputTokens += usage.outputTokens ?? 0;
          keyStats.inputTokens += usage.inputTokens ?? 0;
          keyStats.outputTokens += usage.outputTokens ?? 0;
          delegate.client.close();
          unawaited(iterator.cancel());
          await catalog._saveRouting();
        }
      }
    }
    throw LlmException(
      last == null
          ? 'No available models or keys. Check sources and retry after cooldown.'
          : 'All configured routes failed. Check source health.',
    );
  }
}

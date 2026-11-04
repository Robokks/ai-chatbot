import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../../core/storage.dart';
import '../models.dart';
import 'llm_provider.dart';
import 'source_controls.dart';
export 'source_controls.dart';

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
    Map<String, ModelOptions>? modelOptions,
    QuotaPolicy? quota,
    Map<int, QuotaPolicy>? keyQuotas,
  }) : models = models ?? [],
       modelOptions = modelOptions ?? {},
       quota = quota ?? QuotaPolicy(),
       keyQuotas = keyQuotas ?? {};
  final String id;
  String name;
  String url;
  final ProviderKind kind;
  List<String> models;
  bool enabled;
  bool shared;
  bool requestUsage;
  final Map<String, ModelOptions> modelOptions;
  QuotaPolicy quota;
  final Map<int, QuotaPolicy> keyQuotas;
  bool modelEnabled(String model) =>
      models.contains(model) && (modelOptions[model]?.enabled ?? true);
  Iterable<String> get enabledModels => models.where(modelEnabled);
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
    'options': modelOptions.map((k, v) => MapEntry(k, v.toJson())),
    'quota': quota.toJson(),
    'keyQuotas': keyQuotas.map((k, v) => MapEntry('$k', v.toJson())),
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
    modelOptions: (j['options'] as Map? ?? {}).map(
      (k, v) => MapEntry(
        k as String,
        ModelOptions.fromJson(Map<String, dynamic>.from(v)),
      ),
    ),
    quota: QuotaPolicy.fromJson(Map<String, dynamic>.from(j['quota'] ?? {})),
    keyQuotas: (j['keyQuotas'] as Map? ?? {}).map(
      (k, v) => MapEntry(
        int.parse(k),
        QuotaPolicy.fromJson(Map<String, dynamic>.from(v)),
      ),
    ),
  );
}

/// Public source metadata and encrypted credentials are saved separately.
class NamedSources extends ChangeNotifier {
  NamedSources(
    this.storage, {
    LlmProvider Function(ProviderSettings, String)? factory,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now,
       factory = factory ?? ((s, key) => LlmProvider.create(s, key));
  final Storage storage;
  final DateTime Function() clock;
  final Map<String, QuotaWindow> quotaUsage = {};
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

  ProviderKind kindForChain(RoutingChain chain) {
    final kinds = all
        .where((s) => chain.routes.any((r) => r.startsWith(s.route(''))))
        .map((s) => s.kind)
        .toSet();
    return kinds.length == 1 ? kinds.single : ProviderKind.custom;
  }

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
    if (sources.any((s) => s == null)) {
      throw const FormatException('Choose available models for this chain.');
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
        'quotas': quotaUsage.map((k, v) => MapEntry(k, v.toJson())),
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
                s.modelEnabled(r.substring(s.route('').length)),
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
    quotaUsage.clear();
    if (routing != null) {
      final data = jsonDecode(routing) as Map;
      (data['quotas'] as Map? ?? {}).forEach(
        (k, v) => quotaUsage[k as String] = QuotaWindow.fromJson(
          Map<String, dynamic>.from(v),
        ),
      );
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
    source.quota.validate();
    for (final policy in source.keyQuotas.values) {
      policy.validate();
    }
    if (source.modelOptions.values.any(
      (m) => m.contextTokens != null && m.contextTokens! < 1,
    )) {
      throw const FormatException('Context size must be positive.');
    }
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
        quotaUsage.removeWhere((id, _) => id.startsWith('key:${source.id}:'));
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
    quotaUsage.removeWhere(
      (k, _) => k == 'source:${source.id}' || k.startsWith('key:${source.id}:'),
    );
    metrics.removeWhere((k, _) => k.startsWith(source.route('')));
    keyUsage.removeWhere((k, _) => k.startsWith('${source.id}:'));
    _cooldown.removeWhere((k, _) => k.startsWith('${source.id}:'));
    await _saveRouting();
    await storage.setSetting(
      'lab.sources',
      jsonEncode(all.map((s) => s.toJson()).toList()),
    );
    await storage.writeSecret('lab.source.${source.id}.keys', null);
    notifyListeners();
  }

  int keyCount(NamedSource source) => _keys[source.id]?.length ?? 0;
  QuotaWindow quotaWindow(NamedSource source, [int? key]) {
    final policy = key == null
        ? source.quota
        : source.keyQuotas[key] ?? QuotaPolicy();
    final id = key == null ? 'source:${source.id}' : 'key:${source.id}:$key';
    final now = clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    final start = now ~/ policy.windowSeconds * policy.windowSeconds;
    var entry = quotaUsage[id];
    if (entry == null ||
        entry.start != start ||
        entry.seconds != policy.windowSeconds) {
      entry = quotaUsage[id] = QuotaWindow(
        start: start,
        seconds: policy.windowSeconds,
      );
    }
    return entry;
  }

  String quotaSummary(NamedSource source, [int? key]) {
    final policy = key == null
        ? source.quota
        : source.keyQuotas[key] ?? QuotaPolicy();
    final used = quotaWindow(source, key);
    final reset = DateTime.fromMillisecondsSinceEpoch(
      (used.start + used.seconds) * 1000,
      isUtc: true,
    ).toLocal();
    return '${used.requests}/${policy.requests ?? "∞"} requests · ${used.tokens}/${policy.tokens ?? "∞"} tokens charged · resets $reset${used.unknown > 0 ? " · ${used.unknown} calls have unreported usage; reservations retained" : ""}';
  }

  _QuotaReservation? _reserve(
    NamedSource source,
    int key,
    ChatRequest request,
  ) {
    final policies = [source.quota, source.keyQuotas[key] ?? QuotaPolicy()];
    final windows = [quotaWindow(source), quotaWindow(source, key)];
    int? remaining;
    for (var i = 0; i < policies.length; i++) {
      final p = policies[i], w = windows[i];
      if (p.requests != null && w.requests >= p.requests!) return null;
      if (p.tokens != null) {
        if (w.unknown > 0) return null;
        final available = p.tokens! - w.tokens;
        remaining = remaining == null || available < remaining
            ? available
            : remaining;
      }
    }
    // UTF-8 JSON byte size bounds text tokenization conservatively. Binary content
    // adds its base64-sized budget; extra overhead covers tool/provider framing.
    final input =
        utf8
            .encode(
              jsonEncode({
                'messages': request.messages.map((m) => m.toJson()).toList(),
                'system': request.systemPrompt,
                'tools': request.tools
                    .map(
                      (t) => {
                        'name': t.name,
                        'description': t.description,
                        'schema': t.inputSchema,
                      },
                    )
                    .toList(),
              }),
            )
            .length +
        request.messages
            .expand((m) => m.attachments)
            .fold<int>(0, (n, a) => n + ((a.bytes?.length ?? a.size) * 2)) +
        8192;
    if (remaining != null && remaining <= input) return null;
    final output = remaining == null
        ? request.maxOutputTokens
        : (request.maxOutputTokens == null ||
                  request.maxOutputTokens! > remaining - input
              ? remaining - input
              : request.maxOutputTokens);
    final charge = remaining ?? 0;
    for (final w in windows) {
      w.requests++;
      w.tokens += charge;
    }
    return _QuotaReservation(windows, charge, output);
  }

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
    if (!source.modelEnabled(model)) {
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
        settings: ProviderSettings(
          kind:
              catalog.all
                  .where((s) => routes.any((r) => r.startsWith(s.route(''))))
                  .firstOrNull
                  ?.kind ??
              ProviderKind.custom,
        ),
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
    final protectedHistory = request.messages.reversed
        .where(
          (m) =>
              m.role == Role.assistant &&
              ((m.providerBlocks?.isNotEmpty ?? false) ||
                  m.toolCalls.isNotEmpty),
        )
        .firstOrNull;
    final pinnedKind = protectedHistory?.provider;
    for (final route in routes) {
      final source = catalog.all
          .where((s) => route.startsWith(s.route('')))
          .first;
      if (protectedHistory != null &&
          (pinnedKind == null || source.kind != pinnedKind)) {
        continue;
      }
      final keys = catalog._keys[source.id] ?? [''];
      final available = keys.isEmpty ? [''] : keys;
      final start = catalog._nextKey[source.id] ?? 0;
      for (var attempt = 0; attempt < available.length; attempt++) {
        if (transport.closed) return;
        if (!source.enabled ||
            !source.modelEnabled(route.substring(source.route('').length))) {
          break;
        }
        final index = (start + attempt) % available.length;
        final keyId = '${source.id}:$index';
        if (catalog._cooldown[keyId]?.isAfter(DateTime.now()) ?? false) {
          continue;
        }
        final reservation = catalog._reserve(source, index, request);
        if (reservation == null) continue;
        await catalog._saveRouting();
        if (transport.closed ||
            !source.enabled ||
            !source.modelEnabled(route.substring(source.route('').length))) {
          reservation.release();
          await catalog._saveRouting();
          return;
        }
        catalog._nextKey[source.id] = (index + 1) % available.length;
        late final LlmProvider delegate;
        try {
          delegate = catalog.factory(
            ProviderSettings(
              kind: source.kind,
              baseUrl: source.url,
              models: source.models,
              requestUsage: source.requestUsage,
            ),
            available[index],
          );
        } catch (_) {
          reservation.release();
          await catalog._saveRouting();
          rethrow;
        }
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
              maxOutputTokens: reservation.outputLimit,
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
                providerKind: source.kind,
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
          reservation.settle(usage);
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
          ? 'No available models or keys. Check configured quotas, enabled models and key cooldowns.'
          : 'All configured routes failed. Check source health.',
    );
  }
}

class _QuotaReservation {
  _QuotaReservation(this.windows, this.charged, this.outputLimit);
  final List<QuotaWindow> windows;
  final int charged;
  final int? outputLimit;
  void release() {
    for (final w in windows) {
      w.requests--;
      w.tokens -= charged;
    }
  }

  void settle(UsageStats usage) {
    final known =
        usage.inputTokens != null &&
        usage.outputTokens != null &&
        usage.inputTokens! >= 0 &&
        usage.outputTokens! >= 0;
    for (final w in windows) {
      if (known) {
        w.tokens += usage.inputTokens! + usage.outputTokens! - charged;
      } else {
        w.unknown++;
      }
    }
  }
}

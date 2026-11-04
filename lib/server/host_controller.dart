import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/device_stats.dart';
import '../data/llm/llm_provider.dart';
import '../data/models.dart';
import '../data/lab_role.dart';
import '../state/app_state.dart';
import '../tools/cli_runner.dart';
import 'agent_hub.dart';
import 'discovery.dart';
import 'foreground.dart';
import 'host_server.dart';
import 'openai_bridge.dart';
import 'client_access.dart';
import 'client_connection.dart';
import 'relay_forwarder.dart';
import 'relay_protocol.dart';

/// Host mode: shares this device's models with the user's other devices.
class HostController extends ChangeNotifier implements HostBackend, HostModelBackend {
  HostController(this.app) {
    agents = AgentHub(
      load: () => app.storage.getSetting('host.agents'),
      save: (v) => app.storage.setSetting('host.agents', v),
      log: (device, what, status) => server.logEvent(device, what, status),
    )..addListener(notifyListeners);
    server = HostServer(
      this,
      loadDevices: _loadDevices,
      saveDevices: _saveDevices,
      advertise: advertiseHost,
      agents: agentsSupported ? agents : null,
      webTools: app.tools.builtin,
      webEnabled: (name) => app.tools.enabled && !app.tools.disabledBuiltins.contains(name),
      approvalsRequired: () => app.labRole == LabRole.main || app.labRole == LabRole.relay,
    )..addListener(notifyListeners);
    app.sources.addListener(server.refreshRules);
    _load();
  }

  final AppState app;
  late final HostServer server;

  /// Claude Code / Codex sharing (PC only).
  late final AgentHub agents;
  static bool get agentsSupported => desktopCli;

  /// The web build can't open a server socket.
  static bool get supported => !kIsWeb;

  /// Cloud providers that can be shared (never the network provider itself,
  /// which would loop back to another host).
  static const shareableCloud = [
    ProviderKind.anthropic,
    ProviderKind.openai,
    ProviderKind.deepseek,
    ProviderKind.gemini,
    ProviderKind.openrouter,
    ProviderKind.groq,
    ProviderKind.custom,
  ];

  bool shareLocal = true;
  final Set<ProviderKind> sharedCloud = {};
  int port = defaultHostPort;
  String _name = 'Chatbot host';
  List<String> addresses = [];
  String? error;

  @override
  String get deviceName => _name;

  void _load() {
    final raw = app.storage.getSetting('host.settings');
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      shareLocal = j['shareLocal'] as bool? ?? true;
      server.stopAll = j['stopAll'] as bool? ?? false;
      port = j['port'] as int? ?? defaultHostPort;
      sharedCloud
        ..clear()
        ..addAll([
          for (final n in (j['cloud'] as List? ?? const [])) ?ProviderKind.values.asNameMap()[n],
        ]);
    }
    readDeviceStats().then((d) {
      _name = d.name ?? (kIsWeb ? 'Chatbot host' : Platform.localHostname);
      notifyListeners();
    });
  }

  Future<void> _save() => app.storage.setSetting(
        'host.settings',
        jsonEncode({
          'shareLocal': shareLocal,
          'port': port,
          'stopAll': server.stopAll,
          'cloud': [for (final k in sharedCloud) k.name],
        }),
      );

  Future<List<PairedDevice>> _loadDevices() async {
    final raw = await app.storage.readSecret('host.devices');
    if (raw == null) return [];
    return [
      for (final e in jsonDecode(raw) as List) PairedDevice.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  Future<void> _saveDevices(List<PairedDevice> d) =>
      app.storage.writeSecret('host.devices', jsonEncode([for (final x in d) x.toJson()]));

  Future<void> setStopAll(bool stopped) async {
    server.stopAll = stopped;
    if (stopped) agents.denyAll();
    await _save();
    notifyListeners();
  }

  Future<void> setShareLocal(bool v) async {
    shareLocal = v;
    server.refreshRules();
    await _save();
    notifyListeners();
  }

  Future<void> setShareCloud(ProviderKind k, bool v) async {
    v ? sharedCloud.add(k) : sharedCloud.remove(k);
    server.refreshRules();
    await _save();
    notifyListeners();
  }

  @override
  List<SharedModel> sharedModels() => [
        if (shareLocal && app.hasKey(ProviderKind.local))
          for (final id in app.providers[ProviderKind.local]!.models)
            SharedModel(ProviderKind.local, id, displayName: app.localModels.byId(id)?.name),
        for (final k in shareableCloud)
          if (sharedCloud.contains(k) && app.hasKey(k))
            for (final m in app.providers[k]!.models) SharedModel(k, m),
        for (final source in app.sources.all)
          if (source.enabled && source.shared)
            for (final model in source.models)
              SharedModel(source.kind, source.route(model), displayName: '${source.name} · $model'),
      ];

  @override
  LlmProvider providerForModel(ProviderKind kind, String model) => app.providerFor(kind, modelId: model);

  @override
  LlmProvider providerFor(ProviderKind kind) => app.providerFor(kind);

  String? get primaryAddress => addresses.isEmpty || server.port == null
      ? null
      : '${addresses.first}:${server.port}';

  Future<void> start() async {
    if (server.running) return;
    error = null;
    try {
      if (app.labRole == LabRole.client) throw StateError('Choose Relay in Settings to share Main with downstream PCs.');
      if (app.labRole == LabRole.relay) {
        if (!app.hasKey(ProviderKind.network)) throw StateError('Connect to Main before starting a relay.');
        final settings = app.providers[ProviderKind.network]!;
        final key = app.keyFor(ProviderKind.network);
        final connection = ClientConnection(settings.baseUrl, key);
        try {
          final access = await connection.access();
          final policy = ClientAccess.fromJson(Map<String, dynamic>.from(access['access'] as Map));
          policy.check(stopped: access['stopped'] == true, service: 'relay');
          if (policy.services?.contains('relay') != true) throw StateError('Main must allow Relay forwarding for this PC in Clients → Rules.');
          if (access['id'] is! String || access['serverTime'] is! int) throw StateError('Update Main before using relay mode.');
          server.relay = RelayForwarder(upstream: Uri.parse(settings.baseUrl),
            identity: RelayIdentity(access['id'] as String, key,
              (access['via'] as List? ?? []).map((v) => (v as Map)['id'] as String).toList()),
            clockOffset: Duration(milliseconds: (access['serverTime'] as int) - DateTime.now().toUtc().millisecondsSinceEpoch),
            mcpPort: () => server.mcpPort);
        } finally { connection.close(); }
      } else if (agentsSupported) { await agents.ensureDetected(); }
      await server.start(port: port);
      addresses = await HostServer.localAddresses();
      if (addresses.isEmpty) {
        error = 'No local network address found. Connect this PC to Ethernet or Wi-Fi.';
      }
      await HostForegroundService.start(primaryAddress ?? 'this device');
    } on SocketException catch (e) {
      error = 'Could not start the server on port $port (${e.osError?.message ?? e.message}).';
      await server.stop();
    } catch (e) {
      error = '$e';
      await server.stop();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    agents.denyAll();
    await server.stop();
    await HostForegroundService.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    app.sources.removeListener(server.refreshRules);
    server.removeListener(notifyListeners);
    agents.removeListener(notifyListeners);
    super.dispose();
  }
}

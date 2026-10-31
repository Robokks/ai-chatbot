import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/device_stats.dart';
import '../data/llm/llm_provider.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'discovery.dart';
import 'foreground.dart';
import 'host_server.dart';
import 'openai_bridge.dart';

/// Host mode: shares this device's models with the user's other devices.
class HostController extends ChangeNotifier implements HostBackend {
  HostController(this.app) {
    server = HostServer(
      this,
      loadDevices: _loadDevices,
      saveDevices: _saveDevices,
      advertise: advertiseHost,
    )..addListener(notifyListeners);
    _load();
  }

  final AppState app;
  late final HostServer server;

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

  Future<void> setShareLocal(bool v) async {
    shareLocal = v;
    await _save();
    notifyListeners();
  }

  Future<void> setShareCloud(ProviderKind k, bool v) async {
    v ? sharedCloud.add(k) : sharedCloud.remove(k);
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
      ];

  @override
  LlmProvider providerFor(ProviderKind kind) => app.providerFor(kind);

  String? get primaryAddress => addresses.isEmpty || server.port == null
      ? null
      : '${addresses.first}:${server.port}';

  Future<void> start() async {
    error = null;
    try {
      await server.start(port: port);
      addresses = await HostServer.localAddresses();
      if (addresses.isEmpty) {
        error = 'No Wi-Fi network found. Connect this device to Wi-Fi.';
      }
      await HostForegroundService.start(primaryAddress ?? 'this device');
    } on SocketException catch (e) {
      error = 'Could not start the server on port $port (${e.osError?.message ?? e.message}).';
      await server.stop();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await server.stop();
    await HostForegroundService.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    server.removeListener(notifyListeners);
    super.dispose();
  }
}

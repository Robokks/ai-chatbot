import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/llm/llm_provider.dart';
import '../data/models.dart';
import '../tools/builtin_source.dart';
import '../tools/tool_source.dart';
import 'host_mcp.dart';
import 'client_access.dart';
import 'host_protocols.dart';
import 'openai_bridge.dart';
import 'anthropic_bridge.dart';
import 'responses_bridge.dart';
import 'lab_analytics.dart';
import 'lan_updates.dart';
import 'relay_protocol.dart';
import 'relay_forwarder.dart';
import 'package_proxy.dart';

/// What the host needs from the app: which models it shares and how to
/// reach them.
abstract class HostBackend {
  String get deviceName;
  List<SharedModel> sharedModels();
  LlmProvider providerFor(ProviderKind kind);
}

/// Optional routing support for named sources. Legacy test/backends stay compatible.
abstract class HostModelBackend {
  LlmProvider providerForModel(ProviderKind kind, String model);
}

/// A device (or app) allowed to use the host.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.key,
    DateTime? created,
    this.lastSeen,
    ClientAccess? access,
    ClientUsage? usage,
    this.accessRequested = false,
    Map<String, String>? clientTools,
    List<String>? via,
  }) : created = created ?? DateTime.now(),
       access = access ?? ClientAccess(),
       usage = usage ?? ClientUsage(),
       clientTools = clientTools ?? {},
       via = List.unmodifiable(via ?? const []);

  final String id;
  final String name;
  final String key;
  final DateTime created;
  DateTime? lastSeen;
  ClientAccess access;
  final ClientUsage usage;
  bool accessRequested;
  final Map<String, String> clientTools;
  final List<String> via;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'key': key,
    'created': created.toIso8601String(),
    'access': access.toJson(),
    'usage': usage.toJson(),
    'accessRequested': accessRequested,
    'clientTools': clientTools,
    'via': via,
    if (lastSeen != null) 'lastSeen': lastSeen!.toIso8601String(),
  };

  factory PairedDevice.fromJson(Map<String, dynamic> j) => PairedDevice(
    id: j['id'] as String,
    name: j['name'] as String,
    key: j['key'] as String,
    created: DateTime.parse(j['created'] as String),
    lastSeen: j['lastSeen'] == null
        ? null
        : DateTime.parse(j['lastSeen'] as String),
    access: ClientAccess.fromJson(
      Map<String, dynamic>.from(j['access'] as Map? ?? {}),
    ),
    usage: ClientUsage.fromJson(
      Map<String, dynamic>.from(j['usage'] as Map? ?? {}),
    ),
    accessRequested: j['accessRequested'] as bool? ?? false,
    clientTools: (j['clientTools'] as Map?)?.map(
      (k, v) => MapEntry('$k', '$v'),
    ),
    via: (j['via'] as List?)?.cast<String>(),
  );
}

class HostLogEntry {
  HostLogEntry(this.device, this.model, this.status, {this.outputTokens});
  final DateTime time = DateTime.now();
  final String device;
  final String model;
  final String status;
  final int? outputTokens;
}

/// mDNS service type other devices look for.
const hostServiceType = '_chatbot-ai._tcp';
const defaultHostPort = 8484;

/// Local network server that lets other devices use this device's models
/// through an OpenAI-compatible API.
class HostServer extends ChangeNotifier {
  HostServer(
    this.backend, {
    required this.loadDevices,
    required this.saveDevices,
    this.advertise,
    this.agents,
    this.approvalsRequired,
    this.webTools,
    this.webEnabled,
    this.onAnalytics,
    this.updateCache,
    this.extraTools,
    this.runExtraTool,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// Coding agents shared over MCP (PC hosts only).
  final AgentHost? agents;
  final Future<LanUpdateCache> Function()? updateCache;
  final List<SourceTool> Function()? extraTools;
  final Future<ToolOutput> Function(
    String device,
    String tool,
    Map<String, dynamic> arguments,
    Future<void> cancel,
    VoidCallback recheck,
  )?
  runExtraTool;
  final Future<void> Function(LabRequestEvent)? onAnalytics;
  final BuiltinToolSource? webTools;
  final bool Function(String)? webEnabled;
  final bool Function()? approvalsRequired;
  bool _closing = false;
  bool _stopAll = false;
  bool get stopAll => _stopAll;
  set stopAll(bool value) {
    _stopAll = value;
    notifyListeners();
  }

  final HostBackend backend;
  final Future<List<PairedDevice>> Function() loadDevices;
  final Future<void> Function(List<PairedDevice>) saveDevices;

  /// Starts mDNS advertising; returns a function that stops it.
  final Future<Future<void> Function()> Function(String name, int port)?
  advertise;
  final Random _random;

  static const maxBodyBytes = 25 * 1024 * 1024;
  static const pinLifetime = Duration(minutes: 10);
  static const maxPinAttempts = 5;

  HttpServer? _server;
  RelayForwarder? relay;
  int? packageProxyPort;
  final _relayReplay = RelayReplayCache();
  final _relayTickets =
      <String, ({String id, String method, String path, DateTime expires})>{};
  Timer? _pinTimer;
  String? mcpError;
  HostMcpServer? _mcp;
  Future<void> Function()? _stopAdvertising;
  List<PairedDevice> devices = [];
  final List<HostLogEntry> log = [];
  final _messageReplay =
      <String, ({ProviderKind provider, List<Map<String, dynamic>> blocks})>{};
  int activeRequests = 0;

  String _pin = '';
  DateTime _pinCreated = DateTime.fromMillisecondsSinceEpoch(0);
  int _failedPins = 0;
  DateTime? _lockedUntil;

  bool get running => _server != null;
  int? get port => _server?.port;

  /// MCP (Streamable HTTP) runs on its own port, next to the main one.
  int? get mcpPort => _mcp?.port;

  /// Six-digit pairing code; rotates every 10 minutes and after each pairing.
  String get pin => _pin;

  void newPin() {
    _pinTimer?.cancel();
    if (running) _pinTimer = Timer(pinLifetime, newPin);
    _pin = List.generate(6, (_) => _random.nextInt(10)).join();
    _pinCreated = DateTime.now();
    _failedPins = 0;
    notifyListeners();
  }

  String _newKey() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return 'cbh_${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  Future<void> start({
    int port = defaultHostPort,
    InternetAddress? address,
    bool mcp = true,
  }) async {
    if (running) return;
    _closing = false;
    await loadClients();
    newPin();
    _server = await HttpServer.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    _server!.listen(_handle, onError: (_) {});
    _pinTimer = Timer(pinLifetime, newPin);
    mcpError = null;
    if (mcp) {
      final m = _mcp = HostMcpServer(
        forward: relay?.handle,
        hostName: () => backend.deviceName,
        models: backend.sharedModels,
        run: runPrompt,
        authorize: (req) {
          final d = authenticate(req);
          if (d != null) {
            d.lastSeen = DateTime.now();
            try {
              _checkAccess(d, service: 'mcp');
            } catch (_) {
              return false;
            }
          }
          return d != null;
        },
        agents: agents,
        identify: (req) => authenticate(req)?.id,
        deviceNameFor: (id) => _deviceById(id).name,
        modelsForIdentity: (id) => modelsFor(_deviceById(id)),
        runForIdentity: (id, model, prompt, system) => runPrompt(
          model,
          prompt,
          system,
          device: _deviceById(id).name,
          client: _deviceById(id),
          service: 'mcp',
        ),
        webTools:
            webTools?.tools
                .where(
                  (t) => t.name == 'web_search' || t.name == 'read_web_page',
                )
                .toList() ??
            const [],
        runWebTool: _runWebTool,
        extraToolsFor: extraTools,
        runExtraTool: _runExtraTool,
        watchAccess: _watchAccess,
        checkTool: (id, tool) {
          final d = _deviceById(id);
          _reserveTool(d, tool);
          unawaited(saveDevices(devices));
        },
      );
      try {
        await m.start(port == 0 ? 0 : port + 1);
      } catch (e) {
        mcpError =
            'Could not start MCP on port ${port == 0 ? 'auto' : port + 1}: $e. '
            'MCP tools and coding agents are unavailable.';
        await m.stop();
        _mcp = null;
      }
    }
    try {
      _stopAdvertising = await advertise?.call(
        backend.deviceName,
        _server!.port,
      );
    } catch (_) {
      // Discovery is optional; devices can still type the address.
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _closing = true;
    notifyListeners();
    _pinTimer?.cancel();
    _pinTimer = null;
    relay?.close();
    relay = null;
    _relayTickets.clear();
    await _mcp?.stop();
    _mcp = null;
    await _stopAdvertising?.call();
    _stopAdvertising = null;
    await _server?.close(force: true);
    _server = null;
    _messageReplay.clear();
    notifyListeners();
  }

  Future<void>? _loadClients;
  bool clientsLoaded = false;
  Future<void> loadClients() => _loadClients ??= () async {
    devices = await loadDevices();
    clientsLoaded = true;
    notifyListeners();
  }();

  /// Creates an access key for an app that can't pair with a PIN.
  Future<PairedDevice> createKey(String name) async {
    if (devices.length >= 1000) {
      throw BridgeException(
        'Too many paired PCs. Remove unused keys first.',
        status: 429,
      );
    }
    final d = PairedDevice(
      id: _newKey().substring(4, 16),
      name: name,
      key: _newKey(),
    );
    devices.add(d);
    await saveDevices(devices);
    notifyListeners();
    return d;
  }

  Future<void> revoke(PairedDevice d) async {
    devices.removeWhere((x) => x.id == d.id);
    await saveDevices(devices);
    notifyListeners();
  }

  PairedDevice _deviceById(String id) => devices.firstWhere(
    (d) => d.id == id,
    orElse: () => throw BridgeException('Access key revoked', status: 401),
  );

  Future<ToolOutput> _runWebTool(
    String id,
    String tool,
    Map<String, dynamic> args,
  ) async {
    final d = _deviceById(id);
    _checkAccess(d, service: tool);
    _checkToolAccess(d, [tool]);
    if (webTools == null || !(webEnabled?.call(tool) ?? true)) {
      throw BridgeException('This web tool is disabled on Main.', status: 403);
    }
    final reservation = _reserveTool(d, tool);
    await saveDevices(devices);
    final revoked = Completer<ToolOutput>();
    final unwatch = _watchAccess(id, tool, () {
      if (!revoked.isCompleted) {
        revoked.completeError(
          BridgeException(
            'Access revoked. Ask Main for more access.',
            status: 403,
          ),
        );
      }
    }, tool: tool);
    var status = 'ok';
    try {
      final result = await Future.any([
        Future<ToolOutput>.sync(() {
          final current = _deviceById(id);
          _checkAccess(current, service: tool);
          _checkToolAccess(current, [tool]);
          return webTools!.call(tool, args);
        }),
        revoked.future,
      ]);
      _checkAccess(d, service: tool);
      _checkToolAccess(_deviceById(id), [tool]);
      status = result.isError ? 'error' : 'ok';
      return result;
    } catch (_) {
      status = 'error';
      rethrow;
    } finally {
      unwatch();
      reservation.settle();
      logEvent(d.name, tool, status, deviceId: d.id);
    }
  }

  Future<ToolOutput> _runExtraTool(
    String id,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final device = _deviceById(id);
    _checkToolAccess(device, [tool]);
    if (extraTools?.call().any((t) => t.name == tool) != true ||
        runExtraTool == null) {
      throw BridgeException(
        'LabVIEW tool sharing is off or unavailable.',
        status: 403,
      );
    }
    final reservation = _reserveTool(device, 'labview');
    await saveDevices(devices);
    final cancel = Completer<void>();
    final unwatch = _watchAccess(id, 'labview', () {
      if (!cancel.isCompleted) cancel.complete();
    }, tool: tool);
    void recheck() {
      final current = _deviceById(id);
      _checkAccess(current, service: 'labview');
      _checkToolAccess(current, [tool]);
      if (extraTools?.call().any((t) => t.name == tool) != true) {
        throw BridgeException('LabVIEW sharing is off.', status: 403);
      }
    }

    var status = 'error';
    try {
      final result = await runExtraTool!(
        device.name,
        tool,
        arguments,
        cancel.future,
        recheck,
      );
      status = result.isError ? 'error' : 'ok';
      return result;
    } finally {
      unwatch();
      reservation.settle();
      logEvent(device.name, tool, status, deviceId: device.id);
    }
  }

  Future<void> _updates(HttpRequest req, PairedDevice device) async {
    if (updateCache == null) {
      throw BridgeException('Main update cache is unavailable.', status: 503);
    }
    final reservation = _reserveTool(device, 'updates');
    await saveDevices(devices);
    final cancel = Completer<void>();
    final unwatch = _watchAccess(device.id, 'updates', () {
      if (!cancel.isCompleted) cancel.complete();
    });
    LanUpdateSnapshot? snapshot;
    var status = 'error';
    var streaming = false;
    try {
      final cache = await updateCache!();
      _checkAccess(device, service: 'updates');
      if (cache.manifest == null) {
        throw BridgeException(
          'Main has not cached a Windows update. Ask Main to check updates in Settings.',
          status: 404,
        );
      }
      if (req.uri.path.endsWith('/manifest')) {
        await _json(req.response, 200, cache.manifest!.toJson());
      } else {
        req.response.headers.contentType = ContentType('application', 'zip');
        req.response.headers.set(
          'content-disposition',
          'attachment; filename="$windowsUpdateFilename"',
        );
        snapshot = await cache.openSnapshot();
        _checkAccess(device, service: 'updates');
        req.response.contentLength = snapshot.manifest.bytes;
        // addStream propagates socket backpressure to the bounded file reader.
        // A zero response deadline destroys the underlying connection, including
        // a socket paused by backpressure. close() alone cannot abort addStream.
        unawaited(req.response.done.catchError((_) {}));
        unawaited(
          cancel.future.then((_) async {
            req.response.deadline = Duration.zero;
            try {
              await snapshot?.close();
            } catch (_) {}
          }),
        );
        streaming = true;
        await req.response.addStream(snapshot.read());
        _checkAccess(device, service: 'updates');
        await req.response.close();
      }
      status = 'ok';
    } catch (_) {
      if (!streaming) rethrow;
      // Headers already went to the client: abort instead of writing a JSON
      // error into a partial ZIP or trying to change an already-sent status.
      req.response.deadline = Duration.zero;
    } finally {
      unwatch();
      await snapshot?.close();
      reservation.settle();
      logEvent(device.name, 'updates/windows', status, deviceId: device.id);
    }
  }

  void _checkAccess(PairedDevice device, {String? model, String? service}) {
    if (_closing) throw BridgeException('Main stopped sharing.', status: 503);
    device.access.check(stopped: stopAll, model: model, service: service);
    if (service == 'proxy' || service == 'updates' || service == 'labview') {
      for (final d in [device, ...device.via.map(_deviceById)]) {
        if (d.access.services?.contains(service) != true) {
          throw BridgeException(
            'Main must explicitly allow this service for this PC and its relays.',
            status: 403,
          );
        }
      }
    }
    for (final id in device.via) {
      final parent = _deviceById(id);
      parent.access.check(stopped: stopAll, model: model, service: service);
      if (parent.access.services?.contains('relay') != true) {
        throw BridgeException(
          'An upstream relay is not allowed. Ask Main for access.',
          status: 403,
        );
      }
    }
  }

  ClientReservation _reserveHierarchy(
    PairedDevice device, {
    Map<String, dynamic>? input,
  }) {
    final reservations = <ClientReservation>[];
    try {
      for (final d in [device, ...device.via.map(_deviceById)]) {
        reservations.add(d.usage.reserve(d.access, input: input));
      }
    } catch (_) {
      for (final r in reservations.reversed) {
        r.cancelBeforeRun();
      }
      rethrow;
    }
    final result = reservations.first;
    result.parents.addAll(reservations.skip(1));
    return result;
  }

  ClientReservation _reserveTool(PairedDevice device, String tool) {
    _checkAccess(device, service: tool);
    return _reserveHierarchy(device);
  }

  void refreshRules() => notifyListeners();

  Timer? _expiryTimer(PairedDevice device, VoidCallback inspect) {
    final expires = [
      device,
      ...device.via.map(_deviceById),
    ].map((d) => d.access.expires).whereType<DateTime>().toList()..sort();
    if (expires.isEmpty) return null;
    final remaining = expires.first.difference(DateTime.now());
    return Timer(remaining.isNegative ? Duration.zero : remaining, inspect);
  }

  void _checkToolAccess(PairedDevice device, Iterable<String> tools) {
    final requested = tools.toList();
    for (final d in [device, ...device.via.map(_deviceById)]) {
      if (d.access.tools != null &&
          requested.any((tool) => !d.access.tools!.contains(tool))) {
        throw BridgeException(
          'This tool is not allowed by Main for this PC or its relays.',
          status: 403,
        );
      }
    }
  }

  VoidCallback _watchAccess(
    String id,
    String service,
    VoidCallback onRevoked, {
    String? tool,
  }) {
    Timer? expiry;
    void inspect() {
      expiry?.cancel();
      try {
        final device = _deviceById(id);
        _checkAccess(device, service: service);
        if (tool != null) {
          _checkToolAccess(device, [tool]);
        }
        expiry = _expiryTimer(device, inspect);
      } catch (_) {
        onRevoked();
      }
    }

    addListener(inspect);
    inspect();
    return () {
      expiry?.cancel();
      removeListener(inspect);
    };
  }

  Stream<ChatDelta> _guarded(
    Stream<ChatDelta> source,
    PairedDevice device,
    String model,
    String service,
  ) {
    late StreamController<ChatDelta> out;
    StreamSubscription<ChatDelta>? subscription;
    var finished = false;
    Timer? expiry;
    void fail(Object error) {
      if (finished) return;
      finished = true;
      expiry?.cancel();
      out.addError(error);
      unawaited(subscription?.cancel());
      unawaited(out.close());
    }

    void inspect() {
      expiry?.cancel();
      if (finished) return;
      try {
        _checkAccess(_deviceById(device.id), model: model, service: service);
        if (!backend.sharedModels().any((m) => m.id == model)) {
          throw BridgeException('This model is no longer shared.', status: 403);
        }
        expiry = _expiryTimer(device, inspect);
      } catch (e) {
        fail(e);
      }
    }

    out = StreamController<ChatDelta>(
      onListen: () {
        addListener(inspect);
        inspect();
        if (finished) return;
        subscription = source.listen(
          (delta) {
            inspect();
            if (!finished) out.add(delta);
          },
          onError: fail,
          onDone: () {
            if (!finished) {
              finished = true;
              unawaited(out.close());
            }
          },
        );
      },
      onCancel: () {
        expiry?.cancel();
        removeListener(inspect);
        unawaited(subscription?.cancel());
      },
    );
    return out.stream;
  }

  Stream<ChatDelta> _providerStream(ProviderKind kind, ChatRequest request) {
    LlmProvider? provider;
    StreamSubscription<ChatDelta>? subscription;
    late StreamController<ChatDelta> out;
    out = StreamController<ChatDelta>(
      onListen: () {
        try {
          final routed = backend;
          provider = routed is HostModelBackend
              ? (routed as HostModelBackend).providerForModel(
                  kind,
                  request.model,
                )
              : backend.providerFor(kind);
          subscription = provider!
              .streamChat(request)
              .listen(
                out.add,
                onError: out.addError,
                onDone: () {
                  unawaited(out.close());
                },
              );
        } catch (e, stack) {
          out.addError(e, stack);
          unawaited(out.close());
        }
      },
      onCancel: () {
        provider?.client.close();
        unawaited(subscription?.cancel());
      },
    );
    return out.stream;
  }

  String? _defaultFor(PairedDevice? device) {
    final shared = device == null ? backend.sharedModels() : modelsFor(device);
    return shared.isEmpty
        ? null
        : shared
              .firstWhere(
                (m) => m.kind == ProviderKind.local,
                orElse: () => shared.first,
              )
              .id;
  }

  Future<void> updateAccess(PairedDevice device, ClientAccess access) async {
    if ((access.requestsPerDay ?? 0) < 0 || (access.tokensPerDay ?? 0) < 0) {
      throw ArgumentError('Limits cannot be negative');
    }
    device.access = access;
    device.accessRequested = false;
    await saveDevices(devices);
    notifyListeners();
  }

  List<SharedModel> modelsFor(PairedDevice device) {
    _checkAccess(device);
    return backend
        .sharedModels()
        .where(
          (m) => [device, ...device.via.map(_deviceById)].every(
            (d) => d.access.models == null || d.access.models!.contains(m.id),
          ),
        )
        .toList();
  }

  Future<ClientReservation> _reserve(
    PairedDevice device,
    String model,
    String service,
    Map<String, dynamic> input,
  ) async {
    _checkAccess(device, model: model, service: service);
    if (!backend.sharedModels().any((m) => m.id == model)) {
      throw BridgeException(
        'Model "$model" is not shared by this host',
        status: 404,
        code: 'model_not_found',
      );
    }
    final reservation = _reserveHierarchy(device, input: input);
    try {
      await saveDevices(devices);
    } catch (_) {
      reservation.cancelBeforeRun();
      rethrow;
    }
    notifyListeners();
    return reservation;
  }

  /// IPv4 addresses other devices on the network can use.
  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    for (final iface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final a in iface.addresses) {
        if (!a.isLoopback && !a.isLinkLocal) out.add(a.address);
      }
    }
    return out;
  }

  // HTTP handling

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('access-control-allow-origin', '*')
      ..set(
        'access-control-allow-headers',
        'authorization, content-type, x-api-key',
      )
      ..set('access-control-allow-methods', 'GET, POST, OPTIONS');
    try {
      final path = req.uri.path.replaceAll(RegExp(r'/+$'), '');
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
        return await res.close();
      }
      if (req.method == 'GET' && (path == '/health' || path.isEmpty)) {
        return await _json(res, 200, {
          'app': 'chatbot-host',
          'name': backend.deviceName,
          'version': 1,
        });
      }
      if (req.method == 'POST' && path == '/pair') return await _pair(req);
      if (relay != null) return await relay!.handle(req);
      if (req.method == 'GET' && path == '/.well-known/agent-card.json') {
        return await _json(
          res,
          200,
          a2aAgentCard(
            origin: req.requestedUri.origin,
            hostName: backend.deviceName,
            models: authenticate(req) != null
                ? modelsFor(authenticate(req)!)
                : (approvalsRequired?.call() ?? false)
                ? const []
                : backend.sharedModels(),
          ),
        );
      }

      final device = authenticate(req);
      if (device == null) {
        return await _json(res, 401, {
          if (path == '/v1/messages') 'type': 'error',
          'error': {
            'message': 'Missing or invalid access key. Pair this device or create a key on the host.',
            'type': 'authentication_error',
          },
        });
      }
      device.lastSeen = DateTime.now();
      if (req.method == 'GET' && path == '/access') {
        device.usage.refresh();
        return await _json(res, 200, {
          'id': device.id,
          'device': device.name,
          'main': backend.deviceName,
          'serverTime': DateTime.now().toUtc().millisecondsSinceEpoch,
          'via': [
            for (final id in device.via)
              {
                'id': id,
                'name':
                    devices.where((d) => d.id == id).firstOrNull?.name ??
                    'Unavailable relay',
              },
          ],
          'access': device.access.toJson(),
          'usage': device.usage.toJson(),
          'stopped': stopAll,
          'mcpPort': mcpPort,
          'proxyPort': packageProxyPort,
          'proxyHosts': defaultPackageHosts.toList(),
          'models': device.access.models?.toList(),
        });
      }
      if (req.method == 'POST' && path == '/access/tools') {
        final body = await _readJson(req);
        final tools = body['tools'];
        if (tools is! Map ||
            tools.length > 500 ||
            tools.entries.any(
              (e) =>
                  e.key is! String ||
                  !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(e.key as String) ||
                  e.value is! String,
            )) {
          throw BridgeException('Invalid client tool list');
        }
        final names = tools.map(
          (k, v) => MapEntry(
            k as String,
            (v as String).substring(0, min((v).length, 200)),
          ),
        );
        if (!mapEquals(names, device.clientTools)) {
          device.clientTools
            ..clear()
            ..addAll(names);
          await saveDevices(devices);
          notifyListeners();
        }
        return await _json(res, 200, {'message': 'Tool list updated'});
      }
      if (req.method == 'POST' && path == '/access/request') {
        device.accessRequested = true;
        await saveDevices(devices);
        notifyListeners();
        return await _json(res, 202, {
          'message': 'Access requested. Waiting for Main.',
        });
      }
      if (req.method == 'POST' && path == '/relay') {
        return await _relayRequest(req, device);
      }
      if (req.method == 'GET' && path == '/relay/clients') {
        _checkRelay(device);
        return await _json(res, 200, {
          'clients': [
            for (final child in devices.where((d) => d.via.contains(device.id)))
              {
                'id': child.id,
                'name': child.name,
                'access': child.access.toJson(),
                'via': child.via,
              },
          ],
        });
      }
      _checkAccess(device);
      if (req.method == 'GET' &&
          {
            '/updates/windows/manifest',
            '/updates/windows/archive',
          }.contains(path)) {
        return await _updates(req, device);
      }

      if (req.method == 'GET' && (path == '/v1/models' || path == '/models')) {
        return await _json(res, 200, modelsResponse(modelsFor(device)));
      }
      if (req.method == 'POST' && path == '/v1/responses') {
        return await _responses(req, device);
      }
      if (req.method == 'POST' && path == '/v1/messages') {
        return await _messages(req, device);
      }
      if (req.method == 'POST' &&
          (path == '/v1/chat/completions' || path == '/chat/completions')) {
        return await _chat(req, device);
      }
      if (req.method == 'GET' && path == '/utcp') {
        return await _json(
          res,
          200,
          utcpManual(
            origin: req.requestedUri.origin,
            hostName: backend.deviceName,
            models: modelsFor(device),
          ),
        );
      }
      if (req.method == 'POST' && path == '/tools/chat') {
        return await _toolChat(req, device);
      }
      if (req.method == 'POST' && path == '/a2a') {
        return await _a2a(req, device);
      }
      await _json(res, 404, {
        'error': {
          'message': 'Not found: ${req.method} ${req.uri.path}',
          'type': 'not_found',
        },
      });
    } on BridgeException catch (e) {
      await _json(
        res,
        e.status,
        req.uri.path == '/v1/messages'
            ? anthropicError(e.status, e.message)
            : e.toJson(),
      );
    } catch (e) {
      try {
        await _json(res, 500, {
          'error': {'message': 'Server error: $e', 'type': 'server_error'},
        });
      } catch (_) {}
    }
  }

  /// The paired device whose access key [req] carries, if any.
  PairedDevice? authenticate(HttpRequest req) {
    var token = req.headers.value('x-api-key');
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth != null && auth.toLowerCase().startsWith('bearer ')) {
      token = auth.substring(7).trim();
    }
    if (token == null || token.isEmpty) return null;
    for (final d in devices) {
      if (_constantTimeEquals(d.key, token)) {
        if (d.via.isNotEmpty) {
          final ticket =
              _relayTickets[req.headers.value('x-chatbot-relay-ticket')];
          if (req.connectionInfo?.remoteAddress.isLoopback != true ||
              ticket == null ||
              ticket.id != d.id ||
              ticket.method != req.method ||
              ticket.path != req.uri.toString() ||
              !DateTime.now().isBefore(ticket.expires)) {
            return null;
          }
        }
        return d;
      }
    }
    return null;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > maxBodyBytes) {
        throw BridgeException(
          'Request too large',
          status: 413,
          code: 'too_large',
        );
      }
    }
    try {
      final v = jsonDecode(utf8.decode(bytes));
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
    throw BridgeException('Body must be a JSON object');
  }

  Future<void> _pair(HttpRequest req) async {
    final res = req.response;
    final now = DateTime.now();
    if (_lockedUntil != null && now.isBefore(_lockedUntil!)) {
      return _json(res, 429, {
        'error': {
          'message': 'Too many wrong PINs. Try again in a minute.',
          'type': 'rate_limited',
        },
      });
    }
    final body = await _readJson(req);
    if (now.difference(_pinCreated) >= pinLifetime) newPin();
    final name = (body['device'] as String?)?.trim();
    if (body['pin'] is! String ||
        !_constantTimeEquals(body['pin'] as String, pin)) {
      _failedPins++;
      if (_failedPins >= maxPinAttempts) {
        _lockedUntil = now.add(const Duration(minutes: 1));
        newPin();
      }
      notifyListeners();
      return _json(res, 401, {
        'error': {'message': 'Wrong PIN', 'type': 'authentication_error'},
      });
    }
    if (relay != null) {
      if (await relay!.register(
        res,
        (name == null || name.isEmpty)
            ? 'Device'
            : name.substring(0, min(name.length, 60)),
      )) {
        newPin();
      }
      return;
    }
    if (devices.length >= 1000) {
      throw BridgeException(
        'Too many paired PCs. Remove unused keys first.',
        status: 429,
      );
    }
    final device = PairedDevice(
      id: _newKey().substring(4, 16),
      name: (name == null || name.isEmpty)
          ? 'Device'
          : name.substring(0, min(name.length, 60)),
      key: _newKey(),
      access: ClientAccess(approved: !(approvalsRequired?.call() ?? false)),
      accessRequested: approvalsRequired?.call() ?? false,
    );
    devices.add(device);
    await saveDevices(devices);
    newPin();
    await _json(res, 200, {'key': device.key, 'name': backend.deviceName});
  }

  Future<ProxyGrant> authorizePackageProxy(
    HttpRequest request,
    String key,
    String host,
    int port,
  ) async {
    final device = devices
        .where((d) => _constantTimeEquals(d.key, key))
        .firstOrNull;
    if (device == null) {
      throw BridgeException('Invalid paired PC key.', status: 407);
    }
    final chain = request.headers.value('x-chatbot-proxy-chain');
    if (device.via.isNotEmpty) {
      if (chain == null || chain.length > 16384) {
        throw BridgeException(
          'Connect through the approved relay path.',
          status: 403,
        );
      }
      final RelayEnvelope envelope;
      try {
        envelope = RelayEnvelope.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(utf8.decode(base64Decode(chain))) as Map,
          ),
        );
      } catch (_) {
        throw BridgeException('Malformed package relay chain.', status: 403);
      }
      if (envelope.payload['kind'] != 'proxy' ||
          envelope.payload['key'] != key ||
          envelope.payload['target'] != '$host:$port' ||
          envelope.payload['method'] != request.method ||
          !listEquals(envelope.path, device.via)) {
        throw BridgeException('Invalid package relay path.', status: 403);
      }
      envelope.verify((id) {
        final d = _deviceById(id);
        _checkRelay(d);
        return RelayIdentity(d.id, d.key, d.via);
      }, _relayReplay);
    } else if (chain != null) {
      throw BridgeException('Unexpected relay path.', status: 403);
    }
    final reservation = _reserveTool(device, 'proxy');
    await saveDevices(devices);
    return ProxyGrant(
      groups: [device.id, ...device.via],
      watch: (cancel) => _watchAccess(device.id, 'proxy', cancel),
      finished: (status) {
        reservation.settle();
        logEvent(device.name, 'proxy/$host:$port', status, deviceId: device.id);
      },
    );
  }

  void _checkRelay(PairedDevice device) {
    _checkAccess(device, service: 'relay');
    if (device.access.services?.contains('relay') != true) {
      throw BridgeException(
        'Main must explicitly allow relay forwarding for this PC.',
        status: 403,
      );
    }
  }

  Future<void> _relayRequest(HttpRequest req, PairedDevice outer) async {
    _checkRelay(outer);
    final envelope = RelayEnvelope.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(utf8.decode(await relayBytes(req))) as Map,
      ),
    );
    validateRelayPayload(envelope.payload);
    if (envelope.hops.isEmpty || envelope.hops.last.id != outer.id) {
      throw BridgeException('Relay identity mismatch', status: 403);
    }
    envelope.verify((id) {
      final d = _deviceById(id);
      _checkRelay(d);
      return RelayIdentity(d.id, d.key, d.via);
    }, _relayReplay);
    final payload = envelope.payload;
    if (payload['kind'] == 'register') {
      if (devices.length >= 1000) {
        throw BridgeException(
          'Too many paired PCs. Remove unused keys first.',
          status: 429,
        );
      }
      final child = PairedDevice(
        id: _newKey().substring(4, 16),
        key: _newKey(),
        name: payload['name'] as String,
        access: ClientAccess(approved: false),
        accessRequested: true,
        via: envelope.path,
      );
      devices.add(child);
      await saveDevices(devices);
      notifyListeners();
      return _json(req.response, 200, {
        'key': child.key,
        'name': backend.deviceName,
      });
    }
    final key = payload['key'] as String;
    final child = devices
        .where((d) => _constantTimeEquals(d.key, key))
        .firstOrNull;
    if (child == null || !listEquals(child.via, envelope.path)) {
      throw BridgeException(
        'This PC must connect through its approved relay path.',
        status: 403,
      );
    }
    final target = Uri.parse(payload['path'] as String);
    final destinationPort = target.path == '/mcp' ? mcpPort : port;
    if (destinationPort == null) {
      throw BridgeException('MCP is unavailable on Main.', status: 503);
    }
    final bytes = base64Decode(payload['body'] as String);
    if (bytes.length > maxBodyBytes) {
      throw BridgeException('Request too large', status: 413);
    }
    _relayTickets.removeWhere((_, t) => !DateTime.now().isBefore(t.expires));
    if (_relayTickets.length >= 1024) {
      throw BridgeException('Main is busy. Try again.', status: 429);
    }
    final ticket = _newKey();
    _relayTickets[ticket] = (
      id: child.id,
      method: payload['method'] as String,
      path: target.toString(),
      expires: DateTime.now().add(const Duration(minutes: 1)),
    );
    final client = HttpClient()..autoUncompress = false;
    try {
      final proxy = await client.openUrl(
        payload['method'] as String,
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: destinationPort,
          path: target.path,
          query: target.query.isEmpty ? null : target.query,
        ),
      );
      proxy.followRedirects = false;
      for (final header in (payload['headers'] as Map).entries) {
        proxy.headers.set(header.key as String, header.value);
      }
      proxy.headers.set('authorization', 'Bearer $key');
      proxy.headers.set('x-chatbot-relay-ticket', ticket);
      proxy.add(bytes);
      final response = await proxy.close();
      req.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (!hopHeaders.contains(name.toLowerCase())) {
          req.response.headers.set(name, values);
        }
      });
      req.response.bufferOutput = false;
      unawaited(
        req.response.done.catchError((_) {
          client.close(force: true);
        }),
      );
      await req.response.addStream(response);
      await req.response.close();
    } finally {
      _relayTickets.remove(ticket);
      client.close(force: true);
    }
  }

  Future<void> _responses(HttpRequest req, PairedDevice device) async {
    final body = await _readJson(req);
    final input = parseResponsesRequest(body);
    final parsed = input.request;
    _checkToolAccess(device, parsed.tools.map((t) => t.name));
    final route = SharedModel.parseId(parsed.modelId);
    if (route == null) throw BridgeException('Invalid model id', status: 404);
    for (final message in parsed.messages.where(
      (m) => m.role == Role.assistant && m.toolCalls.isNotEmpty,
    )) {
      final replay =
          _messageReplay[messageReplayKey(device.id, parsed.modelId, message)];
      if (replay != null) {
        message.provider = replay.provider;
        message.providerBlocks = replay.blocks;
      } else if (route.$1 == ProviderKind.gemini) {
        throw BridgeException(
          'Tool context expired on Main. Start a new chat.',
          status: 409,
        );
      }
    }
    final reservation = await _reserve(device, parsed.modelId, 'chat', body);
    final requested = input.maxOutputTokens;
    final cap = reservation.maxOutputTokens;
    final maximum = requested == null
        ? cap
        : cap == null
        ? requested
        : min(requested, cap);
    final writer = CompletionWriter(parsed.modelId);
    final timing = Stopwatch()..start();
    int? firstToken;
    final id = 'resp_${_newKey().substring(4)}';
    final res = req.response;
    Timer? ping;
    StreamSubscription<ChatDelta>? subscription;
    var status = 'ok';
    var cancelled = false;
    void event(String name, Map<String, dynamic> data) {
      try {
        res.write('event: $name\ndata: ${jsonEncode(data)}\n\n');
      } catch (_) {
        cancelled = true;
        unawaited(subscription?.cancel());
      }
    }

    activeRequests++;
    notifyListeners();
    try {
      if (parsed.stream) {
        res.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        res.headers.set('cache-control', 'no-cache');
        res.bufferOutput = false;
        event('response.created', {
          'type': 'response.created',
          'response': {'id': id, 'status': 'in_progress', 'output': []},
        });
        ping = Timer.periodic(const Duration(seconds: 15), (_) {
          try {
            res.write(': keepalive\n\n');
          } catch (_) {}
        });
      }
      final done = Completer<void>();
      Object? failure;
      subscription =
          _guarded(
            _providerStream(
              route.$1,
              ChatRequest(
                model: route.$2,
                messages: parsed.messages,
                systemPrompt: parsed.systemPrompt,
                tools: parsed.tools,
                maxOutputTokens: maximum,
              ),
            ),
            device,
            parsed.modelId,
            'chat',
          ).listen(
            (delta) {
              writer.add(delta);
              if (delta.text.isNotEmpty) {
                firstToken ??= timing.elapsedMilliseconds;
                if (parsed.stream) {
                  event('response.output_text.delta', {
                    'type': 'response.output_text.delta',
                    'item_id': 'msg_final',
                    'output_index': 0,
                    'content_index': 0,
                    'delta': delta.text,
                  });
                }
              }
            },
            onError: (Object e) {
              failure = e;
              if (!done.isCompleted) done.complete();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );
      unawaited(
        res.done.catchError((_) {
          cancelled = true;
          unawaited(subscription?.cancel());
          if (!done.isCompleted) done.complete();
        }),
      );
      await done.future;
      if (cancelled) {
        status = 'cancelled';
        return;
      }
      if (failure != null) {
        throw failure!;
      }
      if (writer.providerBlocks != null && writer.toolCalls.isNotEmpty) {
        final message = Message(
          role: Role.assistant,
          text: writer.text.toString(),
          toolCalls: writer.toolCalls,
        );
        _messageReplay[messageReplayKey(device.id, parsed.modelId, message)] = (
          provider: route.$1,
          blocks: writer.providerBlocks!,
        );
        if (_messageReplay.length > 256) {
          _messageReplay.remove(_messageReplay.keys.first);
        }
      }
      final result = responsesMessage(
        id: id,
        model: parsed.modelId,
        output: responsesOutput(
          writer.text.toString(),
          writer.toolCalls,
          input.customTools,
        ),
        usage: writer.usage,
      );
      if (parsed.stream) {
        for (final part in responsesCompletedEvents(result)) {
          event(part.event, part.data);
        }
        await res.close();
      } else {
        await _json(res, 200, result);
      }
    } catch (e) {
      status = 'error';
      final error = {
        'message': e is BridgeException
            ? e.message
            : 'Provider request failed.',
        'type': 'provider_error',
      };
      if (parsed.stream) {
        event('response.failed', {
          'type': 'response.failed',
          'response': {'id': id, 'status': 'failed', 'error': error},
        });
        await res.close();
      } else {
        await _json(res, e is BridgeException ? e.status : 502, {
          'error': error,
        });
      }
    } finally {
      ping?.cancel();
      unawaited(subscription?.cancel());
      reservation.settle(
        inputTokens: writer.usage.inputTokens,
        outputTokens: writer.usage.outputTokens,
      );
      await saveDevices(devices);
      activeRequests--;
      await onAnalytics?.call(
        LabRequestEvent(
          deviceId: device.id,
          device: device.name,
          model: parsed.modelId,
          status: status,
          inputTokens: writer.usage.inputTokens,
          outputTokens: writer.usage.outputTokens,
          durationMs: timing.elapsedMilliseconds,
          firstTokenMs: firstToken,
        ),
      );
      _logEntry(device.name, parsed.modelId, status, writer.usage.outputTokens);
    }
  }

  Future<void> _messages(HttpRequest req, PairedDevice device) async {
    final body = await _readJson(req);
    final parsed = parseAnthropicRequest(body);
    _checkToolAccess(device, parsed.tools.map((t) => t.name));
    final route = SharedModel.parseId(parsed.modelId);
    if (route == null) throw BridgeException('Invalid model id', status: 404);
    for (final message in parsed.messages.where(
      (m) => m.role == Role.assistant && m.toolCalls.isNotEmpty,
    )) {
      final replay =
          _messageReplay[messageReplayKey(device.id, parsed.modelId, message)];
      if (replay != null) {
        message.provider = replay.provider;
        message.providerBlocks = replay.blocks;
      } else if (route.$1 == ProviderKind.gemini) {
        throw BridgeException(
          'The tool conversation context on Main expired. Start a new chat.',
          status: 409,
        );
      }
    }
    final reservation = await _reserve(device, parsed.modelId, 'chat', body);
    final requested = body['max_tokens'] as int;
    final maximum = reservation.maxOutputTokens == null
        ? requested
        : min(requested, reservation.maxOutputTokens!);
    final stream = _guarded(
      _providerStream(
        route.$1,
        ChatRequest(
          model: route.$2,
          messages: parsed.messages,
          systemPrompt: parsed.systemPrompt,
          tools: parsed.tools,
          maxOutputTokens: maximum,
        ),
      ),
      device,
      parsed.modelId,
      'chat',
    );
    final writer = CompletionWriter(parsed.modelId);
    final timing = Stopwatch()..start();
    int? firstToken;
    final res = req.response;
    final id = 'msg_${_newKey().substring(4)}';
    Timer? ping;
    StreamSubscription<ChatDelta>? subscription;
    var cancelled = false;
    var status = 'ok';
    var textStarted = false;
    var streamedText = false;
    void event(String name, Map<String, dynamic> data) {
      try {
        res.write('event: $name\ndata: ${jsonEncode(data)}\n\n');
      } catch (_) {}
    }

    activeRequests++;
    notifyListeners();
    try {
      if (parsed.stream) {
        res.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        res.headers.set('cache-control', 'no-cache');
        res.bufferOutput = false;
        event('message_start', {
          'type': 'message_start',
          'message': {
            'id': id,
            'type': 'message',
            'role': 'assistant',
            'model': parsed.modelId,
            'content': [],
            'stop_reason': null,
            'stop_sequence': null,
            'usage': {'input_tokens': 0, 'output_tokens': 0},
          },
        });
        ping = Timer.periodic(
          const Duration(seconds: 15),
          (_) => event('ping', {'type': 'ping'}),
        );
      }
      final done = Completer<void>();
      Object? failure;
      subscription = stream.listen(
        (delta) {
          writer.add(delta);
          if (delta.text.isNotEmpty) firstToken ??= timing.elapsedMilliseconds;
          // Native thinking must keep its original order and signature, so it is
          // emitted from the final signed blocks. Other providers stream text live.
          if (parsed.stream &&
              route.$1 != ProviderKind.anthropic &&
              delta.text.isNotEmpty) {
            if (!textStarted) {
              textStarted = true;
              event('content_block_start', {
                'type': 'content_block_start',
                'index': 0,
                'content_block': {'type': 'text', 'text': ''},
              });
            }
            streamedText = true;
            event('content_block_delta', {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': delta.text},
            });
          }
        },
        onError: (Object e) {
          failure = e;
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      unawaited(
        res.done.catchError((_) {
          cancelled = true;
          unawaited(subscription?.cancel());
          if (!done.isCompleted) done.complete();
        }),
      );
      await done.future;
      if (cancelled) {
        status = 'cancelled';
        return;
      }
      if (failure != null) {
        throw failure!;
      }
      if (writer.providerBlocks != null && writer.toolCalls.isNotEmpty) {
        final message = Message(
          role: Role.assistant,
          text: writer.text.toString(),
          toolCalls: writer.toolCalls,
        );
        _messageReplay[messageReplayKey(device.id, parsed.modelId, message)] = (
          provider: route.$1,
          blocks: writer.providerBlocks!,
        );
        if (_messageReplay.length > 256) {
          _messageReplay.remove(_messageReplay.keys.first);
        }
      }
      final content = anthropicContent(
        writer.text.toString(),
        writer.toolCalls,
        nativeBlocks: route.$1 == ProviderKind.anthropic
            ? writer.providerBlocks
            : null,
      );
      final result = anthropicMessage(
        id: id,
        model: parsed.modelId,
        content: content,
        usage: writer.usage,
      );
      if (parsed.stream) {
        var index = 0;
        if (streamedText) {
          event('content_block_stop', {
            'type': 'content_block_stop',
            'index': index++,
          });
        }
        for (final block in content) {
          if (streamedText && block['type'] == 'text') continue;
          for (final part in anthropicBlockEvents(block, index)) {
            event(part.event, part.data);
          }
          index++;
        }
        event('message_delta', {
          'type': 'message_delta',
          'delta': {
            'stop_reason': result['stop_reason'],
            'stop_sequence': null,
          },
          'usage': result['usage'],
        });
        event('message_stop', {'type': 'message_stop'});
        await res.close();
      } else {
        await _json(res, 200, result);
      }
    } catch (e) {
      status = 'error';
      final error = anthropicError(e is BridgeException ? e.status : 502, '$e');
      if (parsed.stream) {
        event('error', error);
        await res.close();
      } else {
        await _json(res, e is BridgeException ? e.status : 502, error);
      }
    } finally {
      ping?.cancel();
      unawaited(subscription?.cancel());
      reservation.settle(
        inputTokens: writer.usage.inputTokens,
        outputTokens: writer.usage.outputTokens,
      );
      await saveDevices(devices);
      activeRequests--;
      _logEntry(device.name, parsed.modelId, status, writer.usage.outputTokens);
    }
  }

  Future<void> _chat(HttpRequest req, PairedDevice device) async {
    final res = req.response;
    final body = await _readJson(req);
    final parsed = parseChatRequest(body);
    _checkToolAccess(device, parsed.tools.map((t) => t.name));
    final route = SharedModel.parseId(parsed.modelId);
    final shared = backend.sharedModels();
    if (route == null || !shared.any((m) => m.id == parsed.modelId)) {
      throw BridgeException(
        'Model "${parsed.modelId}" is not shared by this host',
        status: 404,
        code: 'model_not_found',
      );
    }
    final reservation = await _reserve(device, parsed.modelId, 'chat', body);
    final (kind, model) = route;
    final writer = CompletionWriter(parsed.modelId)..provider = kind;
    final timing = Stopwatch()..start();
    int? firstToken;
    final stream = _guarded(
      _providerStream(
        kind,
        ChatRequest(
          model: model,
          messages: parsed.messages,
          systemPrompt: parsed.systemPrompt,
          tools: parsed.tools,
          maxOutputTokens: reservation.maxOutputTokens,
        ),
      ),
      device,
      parsed.modelId,
      'chat',
    );

    activeRequests++;
    notifyListeners();
    var status = 'ok';
    StreamSubscription<ChatDelta>? sub;
    try {
      if (parsed.stream) {
        res.headers
          ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..set('cache-control', 'no-cache');
        res.bufferOutput = false;
        final done = Completer<void>();
        sub = stream.listen(
          (d) {
            if (d.text.isNotEmpty) firstToken ??= timing.elapsedMilliseconds;
            final chunk = writer.add(d);
            if (chunk != null) _sse(res, chunk);
          },
          onError: (Object e) {
            status = 'error';
            _sse(res, {
              'error': {'message': e.toString(), 'type': 'provider_error'},
            });
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        // Client hung up: stop generating.
        unawaited(
          res.done.catchError((_) {
            status = 'cancelled';
            sub?.cancel();
            if (!done.isCompleted) done.complete();
          }),
        );
        await done.future;
        if (status != 'cancelled') {
          if (status == 'ok') _sse(res, writer.finalChunk());
          final u = writer.usageChunk();
          if (parsed.includeUsage && u != null) _sse(res, u);
          res.write('data: [DONE]\n\n');
          await res.close();
        }
      } else {
        try {
          await for (final d in stream) {
            if (d.text.isNotEmpty) firstToken ??= timing.elapsedMilliseconds;
            writer.add(d);
          }
          await _json(res, 200, writer.completion());
        } catch (e) {
          status = 'error';
          await _json(res, 502, {
            'error': {'message': e.toString(), 'type': 'provider_error'},
          });
        }
      }
    } finally {
      activeRequests--;
      reservation.settle(
        inputTokens: writer.usage.inputTokens,
        outputTokens: writer.usage.outputTokens,
      );
      await saveDevices(devices);
      await onAnalytics?.call(
        LabRequestEvent(
          deviceId: device.id,
          device: device.name,
          model: parsed.modelId,
          status: status,
          inputTokens: writer.usage.inputTokens,
          outputTokens: writer.usage.outputTokens,
          durationMs: timing.elapsedMilliseconds,
          firstTokenMs: firstToken,
        ),
      );
      _logEntry(device.name, parsed.modelId, status, writer.usage.outputTokens);
    }
  }

  /// Default model for tools that don't name one: on-device first.
  String? get defaultModelId {
    final shared = backend.sharedModels();
    if (shared.isEmpty) return null;
    return shared
        .firstWhere(
          (m) => m.kind == ProviderKind.local,
          orElse: () => shared.first,
        )
        .id;
  }

  Stream<ChatDelta> _streamFor(
    String? modelId,
    List<Message> messages,
    String? system, {
    int? maxOutputTokens,
  }) {
    final id = modelId ?? defaultModelId;
    final route = id == null ? null : SharedModel.parseId(id);
    if (route == null || !backend.sharedModels().any((m) => m.id == id)) {
      throw BridgeException(
        'Model "${id ?? ''}" is not shared by this host',
        status: 404,
        code: 'model_not_found',
      );
    }
    return _providerStream(
      route.$1,
      ChatRequest(
        model: route.$2,
        messages: messages,
        systemPrompt: system,
        maxOutputTokens: maxOutputTokens,
      ),
    );
  }

  /// Runs [prompt] on a shared model and returns (answer, model id).
  /// Used by the MCP, UTCP and A2A front ends.
  Future<(String, String)> runPrompt(
    String? model,
    String prompt,
    String? system, {
    String device = 'Tool client',
    PairedDevice? client,
    String service = 'chat',
  }) async {
    final id = model ?? _defaultFor(client) ?? '';
    final reservation = client == null
        ? null
        : await _reserve(client, id, service, {
            'prompt': prompt,
            'system': system,
          });
    final writer = CompletionWriter(id);
    final timing = Stopwatch()..start();
    int? firstToken;
    var status = 'ok';
    activeRequests++;
    notifyListeners();
    try {
      final source = _streamFor(
        id,
        [Message(role: Role.user, text: prompt)],
        system,
        maxOutputTokens: reservation?.maxOutputTokens,
      );
      await for (final d
          in client == null ? source : _guarded(source, client, id, service)) {
        if (d.text.isNotEmpty) firstToken ??= timing.elapsedMilliseconds;
        writer.add(d);
      }
      return (writer.text.toString(), id);
    } catch (_) {
      status = 'error';
      rethrow;
    } finally {
      activeRequests--;
      reservation?.settle(
        inputTokens: writer.usage.inputTokens,
        outputTokens: writer.usage.outputTokens,
      );
      if (client != null) await saveDevices(devices);
      await onAnalytics?.call(
        LabRequestEvent(
          deviceId: client?.id ?? 'local',
          device: device,
          model: id,
          status: status,
          inputTokens: writer.usage.inputTokens,
          outputTokens: writer.usage.outputTokens,
          durationMs: timing.elapsedMilliseconds,
          firstTokenMs: firstToken,
        ),
      );
      _logEntry(device, id, status, writer.usage.outputTokens);
    }
  }

  /// Adds a line to the host's recent requests list.
  void logEvent(String device, String what, String status, {String? deviceId}) {
    _logEntry(device, what, status, null);
    final record = onAnalytics;
    if (record != null) {
      unawaited(
        record(
          LabRequestEvent(
            deviceId:
                deviceId ??
                devices.where((d) => d.name == device).firstOrNull?.id ??
                'local',
            device: device,
            model: what,
            status: status,
            kind: what.startsWith('proxy/')
                ? 'proxy'
                : what.startsWith('updates/')
                ? 'update'
                : 'tool',
          ),
        ).catchError((_) {}),
      );
    }
  }

  void _logEntry(String device, String model, String status, int? tokens) {
    log.insert(0, HostLogEntry(device, model, status, outputTokens: tokens));
    if (log.length > 50) log.removeLast();
    notifyListeners();
  }

  /// Simple REST tool used by the UTCP manual.
  Future<void> _toolChat(HttpRequest req, PairedDevice device) async {
    final body = await _readJson(req);
    final prompt = body['prompt'];
    if (prompt is! String || prompt.trim().isEmpty) {
      throw BridgeException('"prompt" is required');
    }
    try {
      final (text, model) = await runPrompt(
        body['model'] as String?,
        prompt,
        body['system'] as String?,
        device: device.name,
        client: device,
      );
      await _json(req.response, 200, {'text': text, 'model': model});
    } on BridgeException {
      rethrow;
    } catch (e) {
      await _json(req.response, 502, {
        'error': {'message': e.toString(), 'type': 'provider_error'},
      });
    }
  }

  /// A2A 1.0 JSON-RPC: SendMessage and SendStreamingMessage.
  Future<void> _a2a(HttpRequest req, PairedDevice device) async {
    final res = req.response;
    Map<String, dynamic> body;
    try {
      body = await _readJson(req);
    } on BridgeException {
      return _jsonText(
        res,
        200,
        jsonRpcError(null, -32700, 'Invalid JSON payload'),
      );
    }
    final id = body['id'];
    final method = body['method'];
    String newId() => _newKey().substring(4, 24);
    try {
      switch (method) {
        case 'SendMessage' || 'message/send':
          final a = parseA2aSend(body['params'], newId);
          final (text, _) = await runPrompt(
            a.model,
            a.text,
            null,
            device: '${device.name} (A2A)',
            client: device,
            service: 'a2a',
          );
          return await _jsonText(
            res,
            200,
            jsonRpcResult(id, {
              'message': a2aMessage(text, a.contextId, newId()),
            }),
          );
        case 'SendStreamingMessage' || 'message/stream':
          final a = parseA2aSend(body['params'], newId);
          return await _a2aStream(res, id, a, device, newId);
        case 'GetTask' || 'CancelTask' || 'SubscribeToTask':
          return await _jsonText(
            res,
            200,
            jsonRpcError(id, -32001, 'Task not found'),
          );
        default:
          return await _jsonText(
            res,
            200,
            jsonRpcError(id, -32601, 'Method not found'),
          );
      }
    } on A2aError catch (e) {
      return await _jsonText(res, 200, jsonRpcError(id, e.code, e.message));
    } on BridgeException catch (e) {
      return await _jsonText(res, 200, jsonRpcError(id, -32602, e.message));
    } catch (e) {
      return await _jsonText(
        res,
        200,
        jsonRpcError(id, -32603, 'Internal error: $e'),
      );
    }
  }

  Future<void> _a2aStream(
    HttpResponse res,
    Object? id,
    A2aRequest a,
    PairedDevice device,
    String Function() newId,
  ) async {
    final modelId = a.model ?? _defaultFor(device) ?? '';
    final reservation = await _reserve(device, modelId, 'a2a', {
      'prompt': a.text,
    });
    final usage = UsageStats();
    final timing = Stopwatch()..start();
    int? firstToken;
    final stream = _guarded(
      _streamFor(
        modelId,
        [Message(role: Role.user, text: a.text)],
        null,
        maxOutputTokens: reservation.maxOutputTokens,
      ),
      device,
      modelId,
      'a2a',
    );
    final taskId = newId(), artifactId = newId();
    res.headers
      ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..set('cache-control', 'no-cache');
    res.bufferOutput = false;
    void send(Map<String, dynamic> result) {
      try {
        res.write('data: ${jsonRpcResult(id, result)}\n\n');
      } catch (_) {}
    }

    send({
      'task': {
        'id': taskId,
        'contextId': a.contextId,
        'status': {'state': 'TASK_STATE_WORKING'},
      },
    });
    var state = 'TASK_STATE_COMPLETED';
    String? error;
    activeRequests++;
    notifyListeners();
    try {
      await for (final d in stream) {
        device.access.check(stopped: stopAll, model: modelId, service: 'a2a');
        if (d.usage != null) usage.merge(d.usage!);
        if (d.text.isEmpty) continue;
        firstToken ??= timing.elapsedMilliseconds;
        send({
          'artifactUpdate': {
            'taskId': taskId,
            'contextId': a.contextId,
            'artifact': {
              'artifactId': artifactId,
              'parts': [
                {'text': d.text},
              ],
            },
            'append': true,
          },
        });
      }
    } catch (e) {
      state = 'TASK_STATE_FAILED';
      error = e.toString();
    } finally {
      activeRequests--;
      reservation.settle(
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
      );
      await saveDevices(devices);
      await onAnalytics?.call(
        LabRequestEvent(
          deviceId: device.id,
          device: device.name,
          model: modelId,
          status: error == null ? 'ok' : 'error',
          inputTokens: usage.inputTokens,
          outputTokens: usage.outputTokens,
          durationMs: timing.elapsedMilliseconds,
          firstTokenMs: firstToken,
        ),
      );
      _logEntry(
        '${device.name} (A2A)',
        modelId,
        error == null ? 'ok' : 'error',
        usage.outputTokens,
      );
    }
    send({
      'statusUpdate': {
        'taskId': taskId,
        'contextId': a.contextId,
        'status': {
          'state': state,
          if (error != null) 'message': a2aMessage(error, a.contextId, newId()),
        },
      },
    });
    try {
      await res.close();
    } catch (_) {}
  }

  static Future<void> _jsonText(
    HttpResponse res,
    int status,
    String body,
  ) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(body);
    await res.close();
  }

  static void _sse(HttpResponse res, Map<String, dynamic> data) {
    try {
      res.write('data: ${jsonEncode(data)}\n\n');
    } catch (_) {
      // Client disconnected; res.done handles cleanup.
    }
  }

  static Future<void> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}

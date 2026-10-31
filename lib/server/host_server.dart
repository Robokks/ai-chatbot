import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/llm/llm_provider.dart';
import '../data/models.dart';
import 'host_mcp.dart';
import 'host_protocols.dart';
import 'openai_bridge.dart';

/// What the host needs from the app: which models it shares and how to
/// reach them.
abstract class HostBackend {
  String get deviceName;
  List<SharedModel> sharedModels();
  LlmProvider providerFor(ProviderKind kind);
}

/// A device (or app) allowed to use the host.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.key,
    DateTime? created,
    this.lastSeen,
  }) : created = created ?? DateTime.now();

  final String id;
  final String name;
  final String key;
  final DateTime created;
  DateTime? lastSeen;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'key': key,
        'created': created.toIso8601String(),
        if (lastSeen != null) 'lastSeen': lastSeen!.toIso8601String(),
      };

  factory PairedDevice.fromJson(Map<String, dynamic> j) => PairedDevice(
        id: j['id'] as String,
        name: j['name'] as String,
        key: j['key'] as String,
        created: DateTime.parse(j['created'] as String),
        lastSeen: j['lastSeen'] == null ? null : DateTime.parse(j['lastSeen'] as String),
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
    Random? random,
  }) : _random = random ?? Random.secure();

  final HostBackend backend;
  final Future<List<PairedDevice>> Function() loadDevices;
  final Future<void> Function(List<PairedDevice>) saveDevices;

  /// Starts mDNS advertising; returns a function that stops it.
  final Future<Future<void> Function()> Function(String name, int port)? advertise;
  final Random _random;

  static const maxBodyBytes = 25 * 1024 * 1024;
  static const pinLifetime = Duration(minutes: 10);
  static const maxPinAttempts = 5;

  HttpServer? _server;
  HostMcpServer? _mcp;
  Future<void> Function()? _stopAdvertising;
  List<PairedDevice> devices = [];
  final List<HostLogEntry> log = [];
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
  String get pin {
    if (DateTime.now().difference(_pinCreated) > pinLifetime) newPin();
    return _pin;
  }

  void newPin() {
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
    devices = await loadDevices();
    newPin();
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port, shared: true);
    _server!.listen(_handle, onError: (_) {});
    if (mcp) {
      final m = _mcp = HostMcpServer(
        hostName: () => backend.deviceName,
        models: backend.sharedModels,
        run: runPrompt,
        authorize: (req) => authenticate(req) != null,
      );
      try {
        await m.start(port == 0 ? 0 : port + 1);
      } catch (_) {
        _mcp = null; // Port taken: the rest of the server still works.
      }
    }
    try {
      _stopAdvertising = await advertise?.call(backend.deviceName, _server!.port);
    } catch (_) {
      // Discovery is optional; devices can still type the address.
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _mcp?.stop();
    _mcp = null;
    await _stopAdvertising?.call();
    _stopAdvertising = null;
    await _server?.close(force: true);
    _server = null;
    notifyListeners();
  }

  /// Creates an access key for an app that can't pair with a PIN.
  Future<PairedDevice> createKey(String name) async {
    final d = PairedDevice(id: _newKey().substring(4, 16), name: name, key: _newKey());
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

  /// IPv4 addresses other devices on the network can use.
  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
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
      ..set('access-control-allow-headers', 'authorization, content-type, x-api-key')
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
      if (req.method == 'GET' && path == '/.well-known/agent-card.json') {
        return await _json(res, 200, a2aAgentCard(
          origin: req.requestedUri.origin,
          hostName: backend.deviceName,
          models: backend.sharedModels(),
        ));
      }

      final device = authenticate(req);
      if (device == null) {
        return await _json(res, 401, {
          'error': {
            'message': 'Missing or invalid access key. Pair this device or create a key on the host.',
            'type': 'authentication_error',
          },
        });
      }
      device.lastSeen = DateTime.now();

      if (req.method == 'GET' && (path == '/v1/models' || path == '/models')) {
        return await _json(res, 200, modelsResponse(backend.sharedModels()));
      }
      if (req.method == 'POST' && (path == '/v1/chat/completions' || path == '/chat/completions')) {
        return await _chat(req, device);
      }
      if (req.method == 'GET' && path == '/utcp') {
        return await _json(res, 200, utcpManual(
          origin: req.requestedUri.origin,
          hostName: backend.deviceName,
          models: backend.sharedModels(),
        ));
      }
      if (req.method == 'POST' && path == '/tools/chat') return await _toolChat(req, device);
      if (req.method == 'POST' && path == '/a2a') return await _a2a(req, device);
      await _json(res, 404, {
        'error': {'message': 'Not found: ${req.method} ${req.uri.path}', 'type': 'not_found'},
      });
    } on BridgeException catch (e) {
      await _json(res, e.status, e.toJson());
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
    if (auth != null && auth.toLowerCase().startsWith('bearer ')) token = auth.substring(7).trim();
    if (token == null || token.isEmpty) return null;
    for (final d in devices) {
      if (_constantTimeEquals(d.key, token)) return d;
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
        throw BridgeException('Request too large', status: 413, code: 'too_large');
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
        'error': {'message': 'Too many wrong PINs. Try again in a minute.', 'type': 'rate_limited'},
      });
    }
    final body = await _readJson(req);
    final name = (body['device'] as String?)?.trim();
    if (body['pin'] is! String || !_constantTimeEquals(body['pin'] as String, pin)) {
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
    final device = PairedDevice(
      id: _newKey().substring(4, 16),
      name: (name == null || name.isEmpty) ? 'Device' : name.substring(0, min(name.length, 60)),
      key: _newKey(),
    );
    devices.add(device);
    await saveDevices(devices);
    newPin();
    await _json(res, 200, {'key': device.key, 'name': backend.deviceName});
  }

  Future<void> _chat(HttpRequest req, PairedDevice device) async {
    final res = req.response;
    final parsed = parseChatRequest(await _readJson(req));
    final route = SharedModel.parseId(parsed.modelId);
    final shared = backend.sharedModels();
    if (route == null || !shared.any((m) => m.id == parsed.modelId)) {
      throw BridgeException('Model "${parsed.modelId}" is not shared by this host',
          status: 404, code: 'model_not_found');
    }
    final (kind, model) = route;
    final provider = backend.providerFor(kind);
    final writer = CompletionWriter(parsed.modelId);
    final stream = provider.streamChat(ChatRequest(
      model: model,
      messages: parsed.messages,
      systemPrompt: parsed.systemPrompt,
    ));

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
        unawaited(res.done.catchError((_) {
          status = 'cancelled';
          sub?.cancel();
          if (!done.isCompleted) done.complete();
        }));
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
      _logEntry(device.name, parsed.modelId, status, writer.usage.outputTokens);
    }
  }

  /// Default model for tools that don't name one: on-device first.
  String? get defaultModelId {
    final shared = backend.sharedModels();
    if (shared.isEmpty) return null;
    return shared.firstWhere((m) => m.kind == ProviderKind.local, orElse: () => shared.first).id;
  }

  Stream<ChatDelta> _streamFor(String? modelId, List<Message> messages, String? system) {
    final id = modelId ?? defaultModelId;
    final route = id == null ? null : SharedModel.parseId(id);
    if (route == null || !backend.sharedModels().any((m) => m.id == id)) {
      throw BridgeException('Model "${id ?? ''}" is not shared by this host',
          status: 404, code: 'model_not_found');
    }
    return backend
        .providerFor(route.$1)
        .streamChat(ChatRequest(model: route.$2, messages: messages, systemPrompt: system));
  }

  /// Runs [prompt] on a shared model and returns (answer, model id).
  /// Used by the MCP, UTCP and A2A front ends.
  Future<(String, String)> runPrompt(String? model, String prompt, String? system,
      {String device = 'Tool client'}) async {
    final id = model ?? defaultModelId ?? '';
    final writer = CompletionWriter(id);
    var status = 'ok';
    activeRequests++;
    notifyListeners();
    try {
      await for (final d in _streamFor(model, [Message(role: Role.user, text: prompt)], system)) {
        writer.add(d);
      }
      return (writer.text.toString(), id);
    } catch (_) {
      status = 'error';
      rethrow;
    } finally {
      activeRequests--;
      _logEntry(device, id, status, writer.usage.outputTokens);
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
    if (prompt is! String || prompt.trim().isEmpty) throw BridgeException('"prompt" is required');
    try {
      final (text, model) = await runPrompt(
          body['model'] as String?, prompt, body['system'] as String?, device: device.name);
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
      return _jsonText(res, 200, jsonRpcError(null, -32700, 'Invalid JSON payload'));
    }
    final id = body['id'];
    final method = body['method'];
    String newId() => _newKey().substring(4, 24);
    try {
      switch (method) {
        case 'SendMessage' || 'message/send':
          final a = parseA2aSend(body['params'], newId);
          final (text, _) = await runPrompt(a.model, a.text, null, device: '${device.name} (A2A)');
          return await _jsonText(res, 200,
              jsonRpcResult(id, {'message': a2aMessage(text, a.contextId, newId())}));
        case 'SendStreamingMessage' || 'message/stream':
          final a = parseA2aSend(body['params'], newId);
          return await _a2aStream(res, id, a, device, newId);
        case 'GetTask' || 'CancelTask' || 'SubscribeToTask':
          return await _jsonText(res, 200, jsonRpcError(id, -32001, 'Task not found'));
        default:
          return await _jsonText(res, 200, jsonRpcError(id, -32601, 'Method not found'));
      }
    } on A2aError catch (e) {
      return await _jsonText(res, 200, jsonRpcError(id, e.code, e.message));
    } on BridgeException catch (e) {
      return await _jsonText(res, 200, jsonRpcError(id, -32602, e.message));
    } catch (e) {
      return await _jsonText(res, 200, jsonRpcError(id, -32603, 'Internal error: $e'));
    }
  }

  Future<void> _a2aStream(
    HttpResponse res,
    Object? id,
    A2aRequest a,
    PairedDevice device,
    String Function() newId,
  ) async {
    final stream = _streamFor(a.model, [Message(role: Role.user, text: a.text)], null);
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
        if (d.text.isEmpty) continue;
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
      _logEntry('${device.name} (A2A)', a.model ?? defaultModelId ?? '', error == null ? 'ok' : 'error', null);
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

  static Future<void> _jsonText(HttpResponse res, int status, String body) async {
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

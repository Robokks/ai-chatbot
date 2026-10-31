import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/llm/llm_provider.dart';
import '../data/models.dart';
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

  Future<void> start({int port = defaultHostPort, InternetAddress? address}) async {
    if (running) return;
    devices = await loadDevices();
    newPin();
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port, shared: true);
    _server!.listen(_handle, onError: (_) {});
    try {
      _stopAdvertising = await advertise?.call(backend.deviceName, _server!.port);
    } catch (_) {
      // Discovery is optional; devices can still type the address.
    }
    notifyListeners();
  }

  Future<void> stop() async {
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

      final device = _authenticate(req);
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

  PairedDevice? _authenticate(HttpRequest req) {
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
      log.insert(0, HostLogEntry(device.name, parsed.modelId, status,
          outputTokens: writer.usage.outputTokens));
      if (log.length > 50) log.removeLast();
      notifyListeners();
    }
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

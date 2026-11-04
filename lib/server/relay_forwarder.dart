import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'relay_protocol.dart';
import 'openai_bridge.dart';

const relayPaths = {
  '/access',
  '/access/request',
  '/access/tools',
  '/v1/models',
  '/models',
  '/.well-known/agent-card.json',
  '/v1/chat/completions',
  '/chat/completions',
  '/v1/messages',
  '/v1/responses',
  '/updates/windows/manifest',
  '/updates/windows/archive',
  '/utcp',
  '/tools/chat',
  '/a2a',
  '/mcp',
  '/relay/clients',
};
const relayHeaders = {
  'accept',
  'content-type',
  'mcp-session-id',
  'mcp-protocol-version',
  'last-event-id',
  'anthropic-version',
  'anthropic-beta',
  'mcp-method',
  'mcp-name',
};
const hopHeaders = {
  'host',
  'content-length',
  'transfer-encoding',
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'upgrade',
};

String? requestKey(HttpRequest request) {
  final auth = request.headers.value('authorization');
  return auth != null && auth.toLowerCase().startsWith('bearer ')
      ? auth.substring(7).trim()
      : request.headers.value('x-api-key');
}

Future<List<int>> relayBytes(
  Stream<List<int>> stream, {
  int maximum = 36 * 1024 * 1024,
}) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
    if (bytes.length > maximum) {
      throw BridgeException('Relay request is too large', status: 413);
    }
  }
  return bytes;
}

Future<void> relayJson(HttpResponse response, int status, Object body) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

void validateRelayPayload(Map<String, dynamic> payload) {
  if (payload['kind'] == 'register') {
    if (payload['name'] is! String || (payload['name'] as String).length > 60) {
      throw BridgeException('Invalid PC name');
    }
    return;
  }
  final target = payload['path'] is String
      ? Uri.tryParse(payload['path'] as String)
      : null;
  if (payload['kind'] != 'request' ||
      !['GET', 'POST', 'DELETE', 'OPTIONS'].contains(payload['method']) ||
      target == null ||
      target.hasScheme ||
      target.hasAuthority ||
      target.hasFragment ||
      !relayPaths.contains(target.path) ||
      payload['key'] is! String ||
      payload['body'] is! String ||
      payload['headers'] is! Map ||
      (payload['headers'] as Map).entries.any(
        (e) => !relayHeaders.contains(e.key) || e.value is! String,
      )) {
    throw BridgeException(
      'Relay destination or request is not allowed',
      status: 403,
    );
  }
}

/// Relays may only forward the fixed application protocol to their configured Main.
/// All final authentication, policies and model execution remain on Main.
class RelayForwarder {
  RelayForwarder({
    required this.upstream,
    required this.identity,
    this.clockOffset = Duration.zero,
    required this.mcpPort,
    this.proxyPort,
  }) {
    if (!['http', 'https'].contains(upstream.scheme) ||
        upstream.host.isEmpty ||
        upstream.userInfo.isNotEmpty) {
      throw const FormatException('Invalid upstream Main address');
    }
  }
  final Uri upstream;
  final RelayIdentity identity;
  Duration clockOffset;
  final int? Function() mcpPort;
  final int? Function()? proxyPort;
  final _clients = <HttpClient>{};
  bool _closed = false;

  Future<bool> register(HttpResponse response, String name) => _send(
    response,
    RelayEnvelope({'kind': 'register', 'name': name})
        .append(identity, now: DateTime.now().add(clockOffset)),
  );

  Future<void> handle(HttpRequest request) async {
    try {
      if (_closed || _clients.length >= 64) {
        throw BridgeException('Relay is busy or stopped', status: 503);
      }
      final RelayEnvelope envelope;
      if (request.method == 'POST' && request.uri.path == '/relay') {
        envelope = RelayEnvelope.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(utf8.decode(await relayBytes(request))) as Map,
          ),
        );
        if (envelope.hops.isEmpty) {
          throw BridgeException(
            'A forwarded request needs a signed hop',
            status: 403,
          );
        }
      } else {
        final key = requestKey(request);
        if (key == null || key.isEmpty) {
          throw BridgeException('Missing client access key', status: 401);
        }
        final headers = <String, String>{};
        request.headers.forEach((name, values) {
          if (relayHeaders.contains(name.toLowerCase())) {
            headers[name.toLowerCase()] = values.join(', ');
          }
        });
        envelope = RelayEnvelope({
          'kind': 'request',
          'method': request.method,
          'path': Uri(
            path: request.uri.path,
            query: request.uri.query.isEmpty ? null : request.uri.query,
          ).toString(),
          'key': key,
          'body': base64Encode(
            await relayBytes(request, maximum: 25 * 1024 * 1024),
          ),
          'headers': headers,
        });
      }
      validateRelayPayload(envelope.payload);
      await _send(
        request.response,
        envelope.append(identity, now: DateTime.now().add(clockOffset)),
        origin: request.requestedUri.origin,
      );
    } on BridgeException catch (e) {
      await relayJson(request.response, e.status, e.toJson());
    } catch (_) {
      try {
        await relayJson(request.response, 502, {
          'error': {'message': 'Main could not be reached through this relay.'},
        });
      } catch (_) {}
    }
  }

  Future<bool> _send(
    HttpResponse response,
    RelayEnvelope envelope, {
    String? origin,
  }) async {
    if (_closed) throw BridgeException('Relay stopped', status: 503);
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 10);
    _clients.add(client);
    try {
      final request = await client.postUrl(
        upstream.replace(path: '/relay', query: '', fragment: ''),
      );
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set('authorization', 'Bearer ${identity.key}');
      request.write(jsonEncode(envelope.toJson()));
      final result = await request.close();
      response.statusCode = result.statusCode;
      result.headers.forEach((name, values) {
        if (!hopHeaders.contains(name.toLowerCase())) {
          response.headers.set(name, values);
        }
      });
      unawaited(
        response.done.catchError((_) {
          client.close(force: true);
        }),
      );
      if (result.statusCode == 200 &&
          envelope.payload['kind'] == 'request' &&
          Uri.parse(envelope.payload['path'] as String).path == '/access') {
        final metadata = Map<String, dynamic>.from(
          jsonDecode(
            utf8.decode(await relayBytes(result, maximum: 1024 * 1024)),
          ) as Map,
        );
        metadata['mcpPort'] = mcpPort();
        metadata['proxyPort'] = proxyPort?.call();
        metadata['relay'] = identity.id;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(metadata));
        await response.close();
      } else if (result.statusCode == 200 &&
          origin != null &&
          envelope.payload['kind'] == 'request' &&
          {
            '/utcp',
            '/.well-known/agent-card.json',
          }.contains(Uri.parse(envelope.payload['path'] as String).path)) {
        Object? rewrite(Object? value) {
          if (value is List) return value.map(rewrite).toList();
          if (value is Map) {
            return value.map((key, item) {
              final target = key == 'url' && item is String
                  ? Uri.tryParse(item)
                  : null;
              return MapEntry(
                key,
                target != null && relayPaths.contains(target.path)
                    ? '$origin${target.path}${target.hasQuery ? '?${target.query}' : ''}'
                    : rewrite(item),
              );
            });
          }
          return value;
        }

        final metadata = jsonDecode(
          utf8.decode(await relayBytes(result, maximum: 1024 * 1024)),
        );
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(rewrite(metadata)));
        await response.close();
      } else {
        response.bufferOutput = false;
        await response.addStream(result);
        await response.close();
      }
      return result.statusCode == 200;
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  void close() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }
}

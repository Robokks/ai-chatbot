import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'openai_bridge.dart';
import 'relay_forwarder.dart' show hopHeaders;
import 'relay_protocol.dart';

const defaultPackageHosts = {
  'github.com',
  'api.github.com',
  'codeload.github.com',
  'raw.githubusercontent.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'github-cloud.githubusercontent.com',
  'github-cloud.s3.amazonaws.com',
  'pypi.org',
  'files.pythonhosted.org',
  'registry.npmjs.org',
  'npmjs.org',
  'pub.dev',
  'storage.googleapis.com',
};

class ProxyGrant {
  ProxyGrant({required this.groups, required this.watch, this.finished});
  final List<String> groups;
  final void Function() Function(void Function()) watch;
  final void Function(String status)? finished;
}

class ProxyUpstream {
  ProxyUpstream({
    required this.host,
    required this.port,
    this.identity,
    this.token,
    Duration Function()? clockOffset,
  }) : clockOffset = clockOffset ?? (() => Duration.zero);
  final String host;
  final int port;
  final RelayIdentity? identity;
  final String? token;
  final Duration Function() clockOffset;
}

/// Domain-restricted package traffic. CONNECT keeps destination TLS end to end.
/// Main resolves and pins public IPs; relays can only reach their configured proxy.
class PackageProxy {
  PackageProxy({
    this.authorize,
    this.upstream,
    Set<String>? allowedHosts,
    Future<List<InternetAddress>> Function(String)? resolve,
    Future<Socket> Function(InternetAddress, int)? connect,
  }) : allowedHosts = Set.of(allowedHosts ?? defaultPackageHosts),
       resolve = resolve ?? InternetAddress.lookup,
       connect =
           connect ??
           ((address, port) => Socket.connect(
             address,
             port,
             timeout: const Duration(seconds: 5),
           )) {
    if (authorize == null && upstream == null) {
      throw ArgumentError(
        'A proxy needs Main authorization or a fixed upstream',
      );
    }
  }
  final Future<ProxyGrant> Function(HttpRequest, String, String, int)?
  authorize;
  final ProxyUpstream? upstream;
  final Set<String> allowedHosts;
  final Future<List<InternetAddress>> Function(String) resolve;
  final Future<Socket> Function(InternetAddress, int) connect;
  HttpServer? _server;
  final _sockets = <Socket>{};
  final _requests = <HttpClient>{};
  final _handlers = <Future<void>>{};
  final _counts = <String, int>{};
  int _active = 0;
  bool _stopped = false;
  int? get port => _server?.port;

  static bool publicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv6) {
      final mapped =
          b.take(10).every((v) => v == 0) && b[10] == 255 && b[11] == 255;
      if (mapped) {
        return publicAddress(InternetAddress.fromRawAddress(b.sublist(12)));
      }
      return (b[0] & 0xe0) == 0x20 &&
          !(b[0] == 0x20 &&
              b[1] == 0x01 &&
              (b[2] < 2 || b[2] == 0x0d && b[3] == 0xb8)) &&
          !(b[0] == 0x20 && b[1] == 0x02) &&
          !(b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0);
    }
    return !(b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        b[0] >= 224 ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 192 && b[1] == 88 && b[2] == 99) ||
        (b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2)) ||
        (b[0] == 198 &&
            (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100)) ||
        (b[0] == 203 && b[1] == 0 && b[2] == 113));
  }

  static String? token(HttpRequest request) {
    final header = request.headers.value('proxy-authorization');
    if (header == null) return null;
    if (header.toLowerCase().startsWith('bearer ')) {
      return header.substring(7).trim();
    }
    if (header.toLowerCase().startsWith('basic ')) {
      try {
        final text = utf8.decode(base64Decode(header.substring(6).trim()));
        final colon = text.indexOf(':');
        return colon < 0 ? null : text.substring(colon + 1);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  bool allows(String host) => allowedHosts.contains(host);
  Future<void> start({int port = 8486, InternetAddress? address}) async {
    if (_server != null) return;
    final listen = address ?? InternetAddress.anyIPv4;
    if (upstream?.token != null && !listen.isLoopback) {
      throw ArgumentError(
        'A credential-injecting client proxy must bind loopback only',
      );
    }
    _stopped = false;
    _server = await HttpServer.bind(listen, port);
    _server!.listen((request) {
      final handler = _handle(request);
      _handlers.add(handler);
      unawaited(handler.whenComplete(() => _handlers.remove(handler)));
    }, onError: (_) {});
  }

  Future<Socket> _publicConnect(String host, int port) async {
    final addresses = await resolve(host).timeout(const Duration(seconds: 5));
    if (addresses.isEmpty ||
        addresses.any((address) => !publicAddress(address))) {
      throw BridgeException(
        'Private and reserved addresses are not allowed.',
        status: 403,
      );
    }
    for (final address in addresses.take(8)) {
      if (_stopped) throw BridgeException('Proxy stopped.', status: 503);
      try {
        return await connect(address, port);
      } catch (_) {}
    }
    throw BridgeException(
      'The approved package destination could not be reached.',
      status: 502,
    );
  }

  Future<({Socket socket, Stream<List<int>> input})> _viaUpstream(
    String host,
    int port,
    String key,
    HttpRequest original,
  ) async {
    final parent = upstream!;
    RelayEnvelope? envelope;
    final header = original.headers.value('x-chatbot-proxy-chain');
    if (header != null && parent.token == null) {
      if (header.length > 16384) {
        throw BridgeException('Relay chain too large', status: 403);
      }
      envelope = RelayEnvelope.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(utf8.decode(base64Decode(header))) as Map,
        ),
      );
      if (envelope.payload['kind'] != 'proxy' ||
          envelope.payload['key'] != key ||
          envelope.payload['target'] != '$host:$port' ||
          envelope.payload['method'] != 'CONNECT') {
        throw BridgeException('Proxy relay payload mismatch', status: 403);
      }
    }
    envelope ??= RelayEnvelope({
      'kind': 'proxy',
      'key': key,
      'target': '$host:$port',
      'method': 'CONNECT',
    });
    if (parent.identity != null) {
      envelope = envelope.append(
        parent.identity!,
        now: DateTime.now().add(parent.clockOffset()),
      );
    }
    final socket = await Socket.connect(
      parent.host,
      parent.port,
      timeout: const Duration(seconds: 5),
    );
    _sockets.add(socket);
    final headerDone = Completer<int>();
    final headerResult = headerDone.future.timeout(const Duration(seconds: 15));
    unawaited(headerResult.catchError((_) => 502));
    final received = <int>[];
    late StreamSubscription<List<int>> subscription;
    final input = StreamController<List<int>>(
      onCancel: () {
        unawaited(subscription.cancel());
      },
    );
    subscription = socket.listen(
      (chunk) {
        if (!headerDone.isCompleted) {
          received.addAll(chunk);
          final text = latin1.decode(received);
          final end = text.indexOf('\r\n\r\n');
          if (end >= 0) {
            final status =
                int.tryParse(
                  text.split('\r\n').first.split(' ').elementAtOrNull(1) ?? '',
                ) ??
                502;
            headerDone.complete(status);
            if (received.length > end + 4) input.add(received.sublist(end + 4));
          } else if (received.length > 16384) {
            headerDone.completeError(
              BridgeException('Invalid upstream proxy response', status: 502),
            );
          }
        } else {
          input.add(chunk);
        }
      },
      onError: (Object e) {
        if (!headerDone.isCompleted) {
          headerDone.completeError(e);
        } else {
          input.addError(e);
        }
      },
      onDone: () {
        if (!headerDone.isCompleted) {
          headerDone.completeError(
            BridgeException('Upstream proxy disconnected', status: 502),
          );
        }
        unawaited(input.close());
      },
    );
    try {
      socket.write(
        'CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\nProxy-Authorization: Bearer $key\r\n'
        '${envelope.hops.isEmpty ? '' : 'X-Chatbot-Proxy-Chain: ${base64Encode(utf8.encode(jsonEncode(envelope.toJson())))}\r\n'}\r\n',
      );
      await socket.flush();
      final status = await headerResult;
      if (status != 200) {
        throw BridgeException(
          'Main denied the package proxy request. Check this PC access and the allowed destination.',
          status: status,
        );
      }
      return (socket: socket, input: input.stream);
    } catch (_) {
      socket.destroy();
      unawaited(subscription.cancel());
      _sockets.remove(socket);
      rethrow;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    Socket? remote;
    Socket? local;
    HttpClient? http;
    ProxyGrant? grant;
    void Function()? unwatch;
    List<String> groups = [];
    var counted = false;
    var status = 'error';
    try {
      if (_stopped || _active >= 64) {
        throw BridgeException('Package proxy is busy or stopped.', status: 503);
      }
      final isTunnel = request.method == 'CONNECT';
      final Uri target;
      if (isTunnel) {
        if (!RegExp(r'^[A-Za-z0-9.-]+:[0-9]{1,5}$')
            .hasMatch(request.uri.toString())) {
          throw BridgeException('Invalid CONNECT destination', status: 400);
        }
        target = Uri.parse('https://${request.uri}');
        if (target.port != 443) {
          throw BridgeException(
            'CONNECT is restricted to HTTPS port 443.',
            status: 403,
          );
        }
      } else {
        target = request.uri;
        if (target.scheme != 'http' ||
            target.port != 80 ||
            target.userInfo.isNotEmpty ||
            target.hasFragment) {
          throw BridgeException(
            'Use HTTP port 80 or HTTPS CONNECT port 443.',
            status: 403,
          );
        }
      }
      var host = target.host.toLowerCase();
      if (host.endsWith('.')) host = host.substring(0, host.length - 1);
      if (host.isEmpty ||
          InternetAddress.tryParse(host) != null ||
          !allows(host)) {
        throw BridgeException(
          'This package destination is not on Main allowed list.',
          status: 403,
        );
      }
      final key = upstream?.token ?? token(request);
      if (key == null || key.isEmpty) {
        request.response.headers.set(
          'proxy-authenticate',
          'Basic realm="Lab Main"',
        );
        throw BridgeException(
          'A paired PC key is required for this proxy.',
          status: 407,
        );
      }
      grant = upstream == null
          ? await authorize!(request, key, host, target.port)
          : null;
      groups = grant?.groups ?? [sha256.convert(utf8.encode(key)).toString()];
      if (groups.any((id) => (_counts[id] ?? 0) >= 8)) {
        throw BridgeException(
          'This PC or relay has too many active package connections.',
          status: 429,
        );
      }
      _active++;
      for (final id in groups) {
        _counts[id] = (_counts[id] ?? 0) + 1;
      }
      counted = true;
      var revoked = false;
      unwatch = grant?.watch(() {
        revoked = true;
        remote?.destroy();
        local?.destroy();
        http?.close(force: true);
      });
      if (revoked) {
        throw BridgeException('Proxy access was revoked.', status: 403);
      }
      if (isTunnel) {
        final connection = upstream == null
            ? null
            : await _viaUpstream(host, 443, key, request);
        remote = connection?.socket ?? await _publicConnect(host, 443);
        _sockets.add(remote);
        if (revoked || _stopped) {
          throw BridgeException('Proxy stopped.', status: 403);
        }
        local = await request.response.detachSocket(writeHeaders: false);
        _sockets.add(local);
        local.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        await local.flush();
        await Future.any([
          local.addStream(connection?.input ?? remote),
          remote.addStream(local),
        ]);
      } else {
        // HTTP destinations also use a pinned address (or the configured upstream
        // tunnel) and never follow redirects without a fresh allowlist check.
        http = HttpClient()..autoUncompress = false;
        _requests.add(http);
        http.connectionFactory = (uri, proxyHost, proxyPort) async {
          remote = upstream == null
              ? await _publicConnect(host, 80)
              : await Socket.connect(
                  upstream!.host,
                  upstream!.port,
                  timeout: const Duration(seconds: 5),
                );
          _sockets.add(remote!);
          if (revoked || _stopped) {
            remote!.destroy();
            throw BridgeException('Proxy stopped', status: 403);
          }
          return ConnectionTask.fromSocket(
            Future.value(remote!),
            () => remote?.destroy(),
          );
        };
        if (upstream != null) {
          http.findProxy = (_) => 'PROXY ${upstream!.host}:${upstream!.port}';
        }
        final outgoing = await http.openUrl(
          request.method,
          target.replace(host: host),
        );
        outgoing.followRedirects = false;
        request.headers.forEach((name, values) {
          if (!hopHeaders.contains(name.toLowerCase()) &&
              !{
                'host',
                'proxy-authorization',
                'x-chatbot-proxy-chain',
                'x-chatbot-relay-ticket',
              }.contains(name.toLowerCase())) {
            outgoing.headers.set(name, values);
          }
        });
        outgoing.headers.set(
          HttpHeaders.hostHeader,
          target.replace(host: host).authority,
        );
        if (upstream != null) {
          RelayEnvelope? chain;
          final existing = request.headers.value('x-chatbot-proxy-chain');
          if (existing != null && upstream!.token == null) {
            if (existing.length > 16384) {
              throw BridgeException('Relay chain too large', status: 403);
            }
            chain = RelayEnvelope.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(utf8.decode(base64Decode(existing))) as Map,
              ),
            );
            if (chain.payload['kind'] != 'proxy' ||
                chain.payload['target'] != '$host:80' ||
                chain.payload['key'] != key ||
                chain.payload['method'] != request.method) {
              throw BridgeException(
                'Proxy relay payload mismatch',
                status: 403,
              );
            }
          }
          chain ??= RelayEnvelope({
            'kind': 'proxy',
            'key': key,
            'target': '$host:80',
            'method': request.method,
          });
          if (upstream!.identity != null) {
            chain = chain.append(
              upstream!.identity!,
              now: DateTime.now().add(upstream!.clockOffset()),
            );
          }
          outgoing.headers.set('proxy-authorization', 'Bearer $key');
          if (chain.hops.isNotEmpty) {
            outgoing.headers.set(
              'x-chatbot-proxy-chain',
              base64Encode(utf8.encode(jsonEncode(chain.toJson()))),
            );
          }
        }
        await outgoing.addStream(request);
        final response = await outgoing.close();
        request.response.statusCode = response.statusCode;
        response.headers.forEach((name, values) {
          if (!hopHeaders.contains(name.toLowerCase())) {
            request.response.headers.set(name, values);
          }
        });
        request.response.bufferOutput = false;
        final current = http;
        unawaited(
          request.response.done.catchError((_) {
            current.close(force: true);
          }),
        );
        await request.response.addStream(response);
        await request.response.close();
      }
      status = 'ok';
    } catch (e) {
      if (local == null) {
        try {
          request.response.statusCode = e is BridgeException ? e.status : 502;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'error': {
                'message': e is BridgeException
                    ? e.message
                    : 'The package proxy connection failed.',
              },
            }),
          );
          await request.response.close();
        } catch (_) {}
      }
    } finally {
      unwatch?.call();
      grant?.finished?.call(status);
      if (counted) {
        _active--;
        for (final id in groups) {
          _counts[id] = (_counts[id] ?? 1) - 1;
        }
      }
      if (remote != null) _sockets.remove(remote);
      if (local != null) _sockets.remove(local);
      remote?.destroy();
      local?.destroy();
      if (http != null) _requests.remove(http);
      http?.close(force: true);
    }
  }

  Future<void> stop() async {
    _stopped = true;
    await _server?.close(force: true);
    _server = null;
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    for (final client in _requests.toList()) {
      client.close(force: true);
    }
    await Future.wait(_handlers.toList());
  }
}

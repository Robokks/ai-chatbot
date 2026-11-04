import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_chatbot/server/package_proxy.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:ai_chatbot/server/relay_protocol.dart';

void main() {
  test(
    'public destination filter rejects private and reserved IPv4 and IPv6',
    () {
      for (final ip in [
        '127.0.0.1',
        '10.0.0.1',
        '192.168.1.1',
        '100.64.1.1',
        '169.254.1.1',
        '198.18.0.1',
        '203.0.113.1',
        '::1',
        'fc00::1',
        'fe80::1',
        '2001:db8::1',
        '2001::1',
        '2002:7f00:1::1',
        '3fff::1',
        '::ffff:127.0.0.1',
      ]) {
        expect(
          PackageProxy.publicAddress(InternetAddress(ip)),
          isFalse,
          reason: ip,
        );
      }
      expect(PackageProxy.publicAddress(InternetAddress('8.8.8.8')), isTrue);
      expect(
        PackageProxy.publicAddress(InternetAddress('2606:4700:4700::1111')),
        isTrue,
      );
    },
  );

  test(
    'HTTP checks credentials, pins public DNS, and never leaks proxy headers',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = Completer<Map<String, String?>>();
      origin.listen((r) async {
        seen.complete({
          for (final h in [
            'proxy-authorization',
            'x-chatbot-proxy-chain',
            'x-chatbot-relay-ticket',
            'x-test',
            'host',
          ])
            h: r.headers.value(h),
        });
        expect(await utf8.decoder.bind(r).join(), 'payload');
        r.response.write('package');
        await r.response.close();
      });
      final addresses = <String>[];
      final proxy = PackageProxy(
        allowedHosts: {'packages.example'},
        authorize: (request, key, host, port) async {
          if (key != 'secret') throw BridgeException('denied', status: 403);
          expect(host, 'packages.example');
          expect(port, 80);
          return ProxyGrant(groups: ['pc'], watch: (_) => () {});
        },
        resolve: (_) async => [InternetAddress('8.8.8.8')],
        connect: (address, port) {
          addresses.add('${address.address}:$port');
          return Socket.connect('127.0.0.1', origin.port);
        },
      );
      await proxy.start(port: 0, address: InternetAddress.loopbackIPv4);
      final client = HttpClient()
        ..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
      try {
        final missing = await client.getUrl(
          Uri.parse('http://packages.example/pkg'),
        );
        final denied = await missing.close();
        expect(denied.statusCode, 407);
        await denied.drain<void>();
        final req = await client.postUrl(
          Uri.parse('http://packages.example/pkg'),
        );
        req.headers.set(
          'proxy-authorization',
          'Basic ${base64Encode(utf8.encode('pc:secret'))}',
        );
        req.headers.set('x-chatbot-proxy-chain', 'private-chain');
        req.headers.set('x-chatbot-relay-ticket', 'private-ticket');
        req.headers.set('x-test', 'safe');
        req.headers.set('host', 'evil.example');
        req.write('payload');
        final response = await req.close();
        expect(response.statusCode, 200);
        expect(await utf8.decoder.bind(response).join(), 'package');
        expect(await seen.future, {
          'proxy-authorization': null,
          'x-chatbot-proxy-chain': null,
          'x-chatbot-relay-ticket': null,
          'x-test': 'safe',
          'host': 'packages.example',
        });
        expect(addresses, ['8.8.8.8:80']);
      } finally {
        client.close(force: true);
        await proxy.stop();
        await origin.close(force: true);
      }
    },
  );

  test('mixed public/private DNS and disallowed hosts never connect', () async {
    var connects = 0;
    final proxy = PackageProxy(
      allowedHosts: {'packages.example'},
      authorize: (_, _, _, _) async =>
          ProxyGrant(groups: ['pc'], watch: (_) => () {}),
      resolve: (_) async => [
        InternetAddress('8.8.8.8'),
        InternetAddress('127.0.0.1'),
      ],
      connect: (_, _) {
        connects++;
        throw StateError('must never connect');
      },
    );
    await proxy.start(port: 0, address: InternetAddress.loopbackIPv4);
    final client = HttpClient()
      ..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
    try {
      for (final url in [
        'http://packages.example/pkg',
        'http://127.0.0.1/pkg',
        'http://evil.example/pkg',
        'http://packages.example:8080/pkg',
      ]) {
        final r = await client.getUrl(Uri.parse(url));
        r.headers.set('proxy-authorization', 'Bearer secret');
        final response = await r.close();
        expect(response.statusCode, 403, reason: url);
        await response.drain<void>();
      }
      expect(connects, 0);
    } finally {
      client.close(force: true);
      await proxy.stop();
    }
  });

  test(
    'CONNECT tunnel forwards bytes and revocation closes active connection',
    () async {
      final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      echo.listen((socket) {
        accepted.add(socket);
        socket.listen(socket.add);
      });
      void Function()? revoke;
      final finished = Completer<String>();
      final proxy = PackageProxy(
        allowedHosts: {'packages.example'},
        authorize: (_, _, _, _) async => ProxyGrant(
          groups: ['pc'],
          watch: (callback) {
            revoke = callback;
            return () {};
          },
          finished: finished.complete,
        ),
        resolve: (_) async => [InternetAddress('8.8.8.8')],
        connect: (_, _) => Socket.connect('127.0.0.1', echo.port),
      );
      await proxy.start(port: 0, address: InternetAddress.loopbackIPv4);
      final socket = await Socket.connect('127.0.0.1', proxy.port!);
      final header = Completer<String>();
      final payload = Completer<String>();
      final ended = Completer<void>();
      var data = '';
      socket.listen(
        (bytes) {
          data += latin1.decode(bytes);
          if (!header.isCompleted && data.contains('\r\n\r\n')) {
            header.complete(data);
          }
          if (data.contains('hello')) payload.complete(data);
        },
        onDone: ended.complete,
        onError: ended.completeError,
      );
      try {
        socket.write(
          'CONNECT packages.example:443 HTTP/1.1\r\nHost: packages.example:443\r\nProxy-Authorization: Bearer secret\r\n\r\n',
        );
        await socket.flush();
        expect(
          await header.future.timeout(const Duration(seconds: 5)),
          startsWith('HTTP/1.1 200'),
        );
        socket.write('hello');
        await socket.flush();
        expect(
          await payload.future.timeout(const Duration(seconds: 5)),
          contains('hello'),
        );
        revoke!();
        await ended.future.timeout(const Duration(seconds: 5));
        await finished.future.timeout(const Duration(seconds: 5));
      } finally {
        socket.destroy();
        await proxy.stop();
        for (final s in accepted) {
          s.destroy();
        }
        await echo.close();
      }
    },
  );

  test(
    'client loopback and two relays preserve signed leaf identity',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((r) async {
        r.response.write('ok');
        await r.response.close();
      });
      final identity1 = RelayIdentity('r1', 'r1-key', []);
      final identity2 = RelayIdentity('r2', 'r2-key', ['r1']);
      final seen = Completer<RelayEnvelope>();
      final main = PackageProxy(
        allowedHosts: {'packages.example'},
        authorize: (req, key, _, _) async {
          expect(key, 'leaf-key');
          final chain = RelayEnvelope.fromJson(
            jsonDecode(
              utf8.decode(
                base64Decode(req.headers.value('x-chatbot-proxy-chain')!),
              ),
            ) as Map<String, dynamic>,
          );
          chain.verify(
            (id) => id == 'r1' ? identity1 : identity2,
            RelayReplayCache(),
          );
          expect(chain.path, ['r1', 'r2']);
          expect(chain.payload['key'], 'leaf-key');
          seen.complete(chain);
          return ProxyGrant(groups: ['leaf', 'r2', 'r1'], watch: (_) => () {});
        },
        resolve: (_) async => [InternetAddress('8.8.8.8')],
        connect: (_, _) => Socket.connect('127.0.0.1', origin.port),
      );
      await main.start(port: 0, address: InternetAddress.loopbackIPv4);
      final relay1 = PackageProxy(
        allowedHosts: {'packages.example'},
        upstream: ProxyUpstream(
          host: '127.0.0.1',
          port: main.port!,
          identity: identity1,
        ),
      );
      await relay1.start(port: 0, address: InternetAddress.loopbackIPv4);
      final relay2 = PackageProxy(
        allowedHosts: {'packages.example'},
        upstream: ProxyUpstream(
          host: '127.0.0.1',
          port: relay1.port!,
          identity: identity2,
        ),
      );
      await relay2.start(port: 0, address: InternetAddress.loopbackIPv4);
      final local = PackageProxy(
        allowedHosts: {'packages.example'},
        upstream: ProxyUpstream(
          host: '127.0.0.1',
          port: relay2.port!,
          token: 'leaf-key',
        ),
      );
      await expectLater(local.start(port: 0), throwsArgumentError);
      await local.start(port: 0, address: InternetAddress.loopbackIPv4);
      final client = HttpClient()
        ..findProxy = (_) => 'PROXY 127.0.0.1:${local.port}';
      try {
        final response = await (await client.getUrl(
          Uri.parse('http://packages.example/pkg'),
        )).close();
        expect(response.statusCode, 200);
        expect(await utf8.decoder.bind(response).join(), 'ok');
        await seen.future;
      } finally {
        client.close(force: true);
        await local.stop();
        await relay2.stop();
        await relay1.stop();
        await main.stop();
        await origin.close(force: true);
      }
    },
  );
  test('CONNECT passes through a signed relay and closes on stop', () async {
    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    echo.listen((socket) {
      accepted.add(socket);
      socket.listen(socket.add);
    });
    final identity = RelayIdentity('relay', 'relay-key', []);
    final main = PackageProxy(
      allowedHosts: {'packages.example'},
      authorize: (request, key, host, port) async {
        expect(key, 'leaf-key');
        expect(port, 443);
        final chain = RelayEnvelope.fromJson(
          jsonDecode(
            utf8.decode(
              base64Decode(request.headers.value('x-chatbot-proxy-chain')!),
            ),
          ) as Map<String, dynamic>,
        );
        chain.verify((_) => identity, RelayReplayCache());
        expect(chain.payload['method'], 'CONNECT');
        return ProxyGrant(groups: ['leaf', 'relay'], watch: (_) => () {});
      },
      resolve: (_) async => [InternetAddress('8.8.8.8')],
      connect: (_, _) => Socket.connect('127.0.0.1', echo.port),
    );
    await main.start(port: 0, address: InternetAddress.loopbackIPv4);
    final relay = PackageProxy(
      allowedHosts: {'packages.example'},
      upstream: ProxyUpstream(
        host: '127.0.0.1',
        port: main.port!,
        identity: identity,
      ),
    );
    await relay.start(port: 0, address: InternetAddress.loopbackIPv4);
    final socket = await Socket.connect('127.0.0.1', relay.port!);
    final header = Completer<void>();
    final payload = Completer<void>();
    final ended = Completer<void>();
    var received = '';
    socket.listen(
      (bytes) {
        received += latin1.decode(bytes);
        if (received.contains('200 Connection Established') &&
            !header.isCompleted) {
          header.complete();
        }
        if (received.contains('tunnel-payload') && !payload.isCompleted) {
          payload.complete();
        }
      },
      onDone: ended.complete,
      onError: ended.completeError,
    );
    try {
      socket.write(
        'CONNECT packages.example:443 HTTP/1.1\r\nHost: packages.example:443\r\nProxy-Authorization: Bearer leaf-key\r\n\r\n',
      );
      await socket.flush();
      await header.future.timeout(const Duration(seconds: 5));
      socket.write('tunnel-payload');
      await socket.flush();
      await payload.future.timeout(const Duration(seconds: 5));
      await relay.stop().timeout(const Duration(seconds: 5));
      await ended.future.timeout(const Duration(seconds: 5));
    } finally {
      socket.destroy();
      await relay.stop();
      await main.stop();
      for (final s in accepted) {
        s.destroy();
      }
      await echo.close();
    }
  });
}

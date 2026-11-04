import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:ai_chatbot/server/package_proxy.dart';
import 'package:ai_chatbot/server/relay_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'client_access_integration_test.dart' show AccessBackend;

void main() {
  late HostServer host;
  late HttpServer harness;
  late HttpClient client;
  final grants = <ProxyGrant>[];
  PairedDevice pc(
    String id, {
    List<String> via = const [],
    ClientAccess? access,
  }) {
    final device = PairedDevice(
      id: id,
      name: id,
      key: '$id-key',
      via: via,
      access: access,
    );
    host.devices.add(device);
    return device;
  }

  String signed(
    PairedDevice leaf,
    List<PairedDevice> hops, {
    String target = 'pypi.org:443',
    String? key,
  }) {
    var envelope = RelayEnvelope({
      'kind': 'proxy',
      'key': key ?? leaf.key,
      'target': target,
      'method': 'CONNECT',
    });
    for (final hop in hops) {
      envelope = envelope.append(RelayIdentity(hop.id, hop.key, hop.via));
    }
    return base64Encode(utf8.encode(jsonEncode(envelope.toJson())));
  }

  Future<int> authorize(
    PairedDevice device, {
    String? chain,
    String? key,
  }) async {
    final request = await client.openUrl(
      'CONNECT',
      Uri.parse('http://127.0.0.1:${harness.port}'),
    );
    request.headers.set('proxy-authorization', 'Bearer ${key ?? device.key}');
    if (chain != null) request.headers.set('x-chatbot-proxy-chain', chain);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  setUp(() async {
    grants.clear();
    client = HttpClient();
    host = HostServer(
      AccessBackend(),
      loadDevices: () async => [],
      saveDevices: (_) async {},
    );
    harness = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    harness.listen((request) async {
      try {
        grants.add(
          await host.authorizePackageProxy(
            request,
            PackageProxy.token(request) ?? '',
            'pypi.org',
            443,
          ),
        );
        request.response.statusCode = 204;
      } catch (error) {
        request.response.statusCode = error is BridgeException
            ? error.status
            : 500;
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    for (final grant in grants) {
      grant.finished?.call('ok');
    }
    client.close(force: true);
    await harness.close(force: true);
    await host.stop();
    host.dispose();
  });
  test(
    'proxy is explicit opt-in even when old service policy is unrestricted',
    () async {
      final device = pc('pc');
      expect(await authorize(device), 403);
      await host.updateAccess(device, ClientAccess(services: {'chat'}));
      expect(await authorize(device), 403);
      await host.updateAccess(
        device,
        ClientAccess(services: {'proxy'}, requestsPerDay: 1),
      );
      expect(await authorize(device, key: 'wrong-key'), 407);
      expect(await authorize(device), 204);
      expect(grants.single.groups, ['pc']);
      expect(device.usage.requests, 1);
      expect(await authorize(device), 429);
      expect(device.usage.requests, 1);
    },
  );
  test(
    'watcher revokes a granted connection when PC is blocked or key removed',
    () async {
      final device = pc('pc', access: ClientAccess(services: {'proxy'}));
      expect(await authorize(device), 204);
      final revoked = Completer<void>();
      final unwatch = grants.single.watch(revoked.complete);
      await host.updateAccess(
        device,
        ClientAccess(blocked: true, services: {'proxy'}),
      );
      await revoked.future.timeout(const Duration(seconds: 1));
      unwatch();
      await host.updateAccess(device, ClientAccess(services: {'proxy'}));
      expect(await authorize(device), 204);
      final removed = Completer<void>();
      final unwatch2 = grants.last.watch(removed.complete);
      await host.revoke(device);
      await removed.future.timeout(const Duration(seconds: 1));
      unwatch2();
    },
  );
  test(
    'signed relayed leaf requires exact path, leaf key and destination',
    () async {
      final outer = pc(
        'outer',
        access: ClientAccess(services: {'relay', 'proxy'}),
      );
      final inner = pc(
        'inner',
        via: ['outer'],
        access: ClientAccess(services: {'relay', 'proxy'}),
      );
      final leaf = pc(
        'leaf',
        via: ['outer', 'inner'],
        access: ClientAccess(services: {'proxy'}),
      );
      expect(await authorize(leaf), 403);
      expect(await authorize(leaf, chain: signed(leaf, [outer])), 403);
      expect(
        await authorize(
          leaf,
          chain: signed(leaf, [inner, outer], target: 'evil.example:443'),
        ),
        403,
      );
      expect(
        await authorize(
          leaf,
          chain: signed(leaf, [inner, outer], key: 'wrong-leaf'),
        ),
        403,
      );
      final valid = signed(leaf, [inner, outer]);
      expect(await authorize(leaf, chain: valid), 204);
      expect(grants.single.groups, ['leaf', 'outer', 'inner']);
      expect(
        [leaf.usage.requests, outer.usage.requests, inner.usage.requests],
        [1, 1, 1],
      );
      expect(
        await authorize(leaf, chain: valid),
        403,
        reason: 'signed envelopes cannot be replayed',
      );
      expect(
        await authorize(outer, chain: signed(outer, [inner])),
        403,
        reason: 'direct PC cannot invent a relay path',
      );
    },
  );
  test(
    'ancestor opt-in, limits, blocks and revocation govern downstream proxy',
    () async {
      final relay = pc('relay', access: ClientAccess(services: {'relay'}));
      final leaf = pc(
        'leaf',
        via: ['relay'],
        access: ClientAccess(services: {'proxy'}),
      );
      expect(await authorize(leaf, chain: signed(leaf, [relay])), 403);
      await host.updateAccess(
        relay,
        ClientAccess(services: {'relay', 'proxy'}, requestsPerDay: 0),
      );
      expect(await authorize(leaf, chain: signed(leaf, [relay])), 429);
      expect(
        leaf.usage.requests,
        0,
        reason: 'ancestor failure rolls back leaf request',
      );
      await host.updateAccess(
        relay,
        ClientAccess(services: {'relay', 'proxy'}),
      );
      expect(await authorize(leaf, chain: signed(leaf, [relay])), 204);
      final revoked = Completer<void>();
      final unwatch = grants.single.watch(revoked.complete);
      await host.updateAccess(
        relay,
        ClientAccess(blocked: true, services: {'relay', 'proxy'}),
      );
      await revoked.future.timeout(const Duration(seconds: 1));
      unwatch();
      expect(await authorize(leaf, chain: signed(leaf, [relay])), 403);
    },
  );
}

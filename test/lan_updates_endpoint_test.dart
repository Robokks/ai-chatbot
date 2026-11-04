import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/lan_updates.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Backend implements HostBackend {
  @override
  String get deviceName => 'Main';
  @override
  List<SharedModel> sharedModels() => [];
  @override
  LlmProvider providerFor(ProviderKind kind) => throw UnimplementedError();
}

void main() {
  late Directory directory;
  late LanUpdateCache cache;
  late HostServer server;
  late Uri base;
  late http.Client client;
  late List<int> payload;
  late int assetId;
  late PairedDevice device;
  Future<http.Response> get(String path, {String? key = 'test-device-key'}) =>
      client.get(
        base.replace(path: path),
        headers: {if (key != null) 'Authorization': 'Bearer $key'},
      );
  setUp(() async {
    assetId = 123;
    payload = List<int>.generate(128 * 1024, (i) => i % 256);
    directory = await Directory.systemTemp.createTemp('update-endpoint');
    cache = LanUpdateCache(
      directory: directory,
      client: MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode({
              'tag_name': 'latest',
              'published_at': '2026-11-04T00:00:00Z',
              'assets': [
                {
                  'name': windowsUpdateFilename,
                  'id': assetId,
                  'size': payload.length,
                  'browser_download_url':
                      'https://github.com/Robokks/ai-chatbot/releases/download/latest/$windowsUpdateFilename',
                },
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(payload, 200);
      }),
    );
    await cache.refresh();
    device = PairedDevice(
      id: 'client',
      name: 'Lab PC',
      key: 'test-device-key',
      access: ClientAccess(approved: true, services: {'updates'}),
    );
    server = HostServer(
      _Backend(),
      loadDevices: () async => [device],
      saveDevices: (_) async {},
      updateCache: () async => cache,
      updateAdvertisement: () async => cache.advertisement,
    );
    await server.start(port: 0, address: InternetAddress.loopbackIPv4);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    client = http.Client();
  });
  tearDown(() async {
    client.close();
    await server.stop();
    cache.close();
    await directory.delete(recursive: true);
  });

  test('access advertises only verified updates to PCs with explicit update access', () async {
    var access = jsonDecode((await get('/access')).body) as Map;
    expect((access['windowsUpdate'] as Map)['sha256'], cache.manifest!.sha256Hex);
    device.access = ClientAccess(approved: true, services: {'chat'});
    access = jsonDecode((await get('/access')).body) as Map;
    expect(access['windowsUpdate'], isNull);
    device.access = ClientAccess(approved: true, services: {'updates'}, blocked: true);
    access = jsonDecode((await get('/access')).body) as Map;
    expect(access['windowsUpdate'], isNull);
  });

  test('update endpoints authenticate, enforce explicit service and count downloads', () async {
    expect((await get('/updates/windows/manifest', key: null)).statusCode, 401);
    device.access = ClientAccess(approved: true);
    expect((await get('/updates/windows/manifest')).statusCode, 403);
    device.access = ClientAccess(
      approved: true,
      services: {'updates'},
      requestsPerDay: 2,
    );
    final info = await get('/updates/windows/manifest');
    expect(info.statusCode, 200);
    expect(jsonDecode(info.body)['sha256'], cache.manifest!.sha256Hex);
    final archive = await get('/updates/windows/archive');
    expect(archive.statusCode, 200);
    expect(archive.bodyBytes, payload);
    expect(archive.headers['content-type'], contains('application/zip'));
    expect((await get('/updates/windows/archive')).statusCode, 429);
    expect(device.usage.requests, 2);
    expect(server.log.where((l) => l.model == 'updates/windows').length, 2);
  });

  test('block, expiry and Stop all revoke future update requests', () async {
    device.access = ClientAccess(
      approved: true,
      services: {'updates'},
      blocked: true,
    );
    expect((await get('/updates/windows/archive')).statusCode, 403);
    device.access = ClientAccess(
      approved: true,
      services: {'updates'},
      expires: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    expect((await get('/updates/windows/archive')).statusCode, 403);
    device.access = ClientAccess(approved: true, services: {'updates'});
    server.stopAll = true;
    server.refreshRules();
    expect((await get('/updates/windows/manifest')).statusCode, 403);
  });

  test('blocking a PC interrupts an active archive transfer', () async {
    payload = List<int>.filled(16 * 1024 * 1024, 17);
    await cache.refresh();
    final socketClient = HttpClient();
    try {
      final request = await socketClient.getUrl(
        base.replace(path: '/updates/windows/archive'),
      );
      request.headers.set('Authorization', 'Bearer test-device-key');
      final response = await request.close();
      expect(response.statusCode, 200);
      final first = Completer<void>();
      final done = Completer<void>();
      var received = 0;
      response.listen(
        (bytes) {
          received += bytes.length;
          if (!first.isCompleted) first.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await first.future.timeout(const Duration(seconds: 5));
      device.access.blocked = true;
      server.refreshRules();
      await done.future.timeout(const Duration(seconds: 5));
      expect(received, lessThan(payload.length));
    } finally {
      socketClient.close(force: true);
    }
  });

  test(
    'closing a client cancels its download and releases Main cache snapshot',
    () async {
      payload = List<int>.filled(16 * 1024 * 1024, 18);
      assetId++;
      await cache.refresh();
      final downloader = LanUpdateClient(
        baseUrl: base.toString(),
        keyProvider: () async => device.key,
      );
      final download = downloader.downloadTo(
        Directory('${directory.path}/client-download'),
        cache.manifest!,
      );
      final finished = expectLater(download, throwsA(anything));
      final started = Stopwatch()..start();
      while (cache.activeDownloads == 0 &&
          started.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(cache.activeDownloads, 1);
      downloader.close();
      await finished;
      while (cache.activeDownloads != 0 &&
          started.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(cache.activeDownloads, 0);
      expect(
        await Directory('${directory.path}/client-download').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'cache refresh cannot replace a pinned active download generation',
    () async {
      final snapshot = await cache.openSnapshot();
      var refreshed = false;
      assetId++;
      final future = cache.refresh().then((_) => refreshed = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(refreshed, isFalse);
      expect(await snapshot.read().expand((bytes) => bytes).toList(), payload);
      await future;
      expect(refreshed, isTrue);
    },
  );
}

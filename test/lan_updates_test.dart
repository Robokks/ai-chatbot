import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/server/lan_updates.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory dir;
  final payload = utf8.encode('test windows zip archive');
  String hash(List<int> bytes) => sha256.convert(bytes).toString();
  Map<String, dynamic> release({String? url, int? size, String? digest}) => {
    'tag_name': 'latest',
    'published_at': '2026-11-04T00:00:00Z',
    'assets': [
      {
        'id': 123,
        'name': windowsUpdateFilename,
        'browser_download_url':
            url ??
            'https://github.com/Robokks/ai-chatbot/releases/download/latest/$windowsUpdateFilename',
        'size': size ?? payload.length,
        'digest': ?digest,
      },
    ],
  };
  LanUpdateManifest manifest({String? digest, int? size}) => LanUpdateManifest(
    release: 'latest · asset 123',
    publishedAt: DateTime.utc(2026, 11, 4),
    bytes: size ?? payload.length,
    sha256Hex: digest ?? hash(payload),
  );
  setUp(() async => dir = await Directory.systemTemp.createTemp('lan-updates'));
  tearDown(() async => dir.delete(recursive: true));

  test('Main caches only official Windows release and reload verifies persisted checksum', () async {
    final requested = <Uri>[];
    final cache = LanUpdateCache(
      directory: dir,
      client: MockClient((r) async {
        requested.add(r.url);
        if (r.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode(release(digest: 'sha256:${hash(payload)}')),
            200,
          );
        }
        return http.Response.bytes(payload, 200);
      }),
    );
    final info = await cache.refresh();
    expect(
      requested.first.path,
      '/repos/Robokks/ai-chatbot/releases/tags/latest',
    );
    expect(info.bytes, payload.length);
    expect(info.sha256Hex, hash(payload));
    expect(await cache.archive.readAsBytes(), payload);
    final restarted = LanUpdateCache(directory: dir);
    await restarted.load();
    expect(restarted.manifest?.sha256Hex, info.sha256Hex);
    await cache.archive.writeAsString('tampered');
    await restarted.load();
    expect(restarted.manifest, isNull);
    restarted.close();
  });

  test('failed refresh retains previous verified release and removes partial archive', () async {
    var fail = false;
    final cache = LanUpdateCache(
      directory: dir,
      client: MockClient((r) async {
        if (r.url.host == 'api.github.com') {
          return http.Response(jsonEncode(release()), 200);
        }
        return http.Response.bytes(fail ? [1] : payload, 200);
      }),
    );
    final old = await cache.refresh();
    fail = true;
    await expectLater(cache.refresh(), throwsFormatException);
    expect(cache.manifest, same(old));
    expect(await cache.archive.readAsBytes(), payload);
    expect(await File('${cache.archive.path}.partial').exists(), isFalse);
  });

  test('untrusted release URLs and oversized archives never download', () async {
    for (final data in [
      release(url: 'https://evil.example/$windowsUpdateFilename'),
      release(
        url:
            'https://github.com/other/repo/releases/download/latest/$windowsUpdateFilename',
      ),
      release(size: maxWindowsUpdateBytes + 1),
    ]) {
      var calls = 0;
      final cache = LanUpdateCache(
        directory: dir,
        client: MockClient((r) async {
          calls++;
          return http.Response(jsonEncode(data), 200);
        }),
      );
      await expectLater(cache.refresh(), throwsFormatException);
      expect(calls, 1);
    }
  });

  test(
    'GitHub supplied SHA256 mismatch is rejected before cache publication',
    () async {
      final cache = LanUpdateCache(
        directory: dir,
        client: MockClient(
          (r) async => r.url.host == 'api.github.com'
              ? http.Response(
                  jsonEncode(release(digest: 'sha256:${'0' * 64}')),
                  200,
                )
              : http.Response.bytes(payload, 200),
        ),
      );
      await expectLater(cache.refresh(), throwsFormatException);
      expect(cache.manifest, isNull);
      expect(await cache.archive.exists(), isFalse);
    },
  );

  test(
    'client authenticates both fixed LAN endpoints and verifies download',
    () async {
      final paths = <String>[];
      final client = LanUpdateClient(
        baseUrl: 'http://192.168.1.10:8484/v1',
        keyProvider: () async => 'pc-test-key',
        client: MockClient((r) async {
          expect(r.headers['Authorization'], 'Bearer pc-test-key');
          expect(r.followRedirects, isFalse);
          paths.add(r.url.path);
          return r.url.path.endsWith('/manifest')
              ? http.Response(
                  jsonEncode(manifest().toJson()),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                )
              : http.Response.bytes(payload, 200);
        }),
      );
      final info = await client.fetchManifest();
      final file = await client.downloadTo(dir, info);
      expect(paths, ['/updates/windows/manifest', '/updates/windows/archive']);
      expect(await file.readAsBytes(), payload);
      // Re-downloading a matching file does not consume the network again.
      await client.downloadTo(dir, info);
      expect(paths.length, 2);
    },
  );

  test(
    'client rejects denied access, missing credentials and endpoint redirects',
    () async {
      for (final code in [302, 401, 403]) {
        final client = LanUpdateClient(
          baseUrl: 'http://main:8484',
          keyProvider: () async => 'pc-key',
          client: MockClient(
            (r) async => http.Response(
              '',
              code,
              headers: {'location': 'https://evil.example'},
            ),
          ),
        );
        await expectLater(
          client.fetchManifest(),
          throwsA(isA<HttpException>()),
        );
      }
      var called = false;
      final missing = LanUpdateClient(
        baseUrl: 'http://main:8484',
        keyProvider: () async => null,
        client: MockClient((r) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(missing.fetchManifest(), throwsFormatException);
      expect(called, isFalse);
    },
  );

  test(
    'bad checksum or oversized/incomplete response leaves no client ZIP',
    () async {
      for (final bytes in [
        [...payload]..[0] = 0,
        payload.sublist(1),
        [...payload, 0],
      ]) {
        final client = LanUpdateClient(
          baseUrl: 'http://main:8484',
          keyProvider: () async => 'pc-key',
          client: MockClient((r) async => http.Response.bytes(bytes, 200)),
        );
        await expectLater(
          client.downloadTo(dir, manifest()),
          throwsFormatException,
        );
        expect(await dir.list().toList(), isEmpty);
      }
    },
  );

  test('existing different destination is preserved and unsafe manifest names rejected', () async {
    final file = File('${dir.path}/$windowsUpdateFilename');
    await file.writeAsString('do not overwrite');
    final client = LanUpdateClient(
      baseUrl: 'http://main:8484',
      keyProvider: () async => 'pc-key',
      client: MockClient((r) async => throw StateError('Must not download')),
    );
    await expectLater(
      client.downloadTo(dir, manifest()),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file.readAsString(), 'do not overwrite');
    expect(
      () => LanUpdateManifest.fromJson({
        ...manifest().toJson(),
        'filename': '../ai_chatbot.exe',
      }),
      throwsFormatException,
    );
    expect(
      () => LanUpdateManifest.fromJson({
        ...manifest().toJson(),
        'bytes': maxWindowsUpdateBytes + 1,
      }),
      throwsFormatException,
    );
  });
}

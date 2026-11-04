import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:ai_chatbot/server/coding_client_setup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'coding environments override inherited credential and endpoint conflicts',
    () {
      final env = CodingClientSetup.claude(
        localUrl: Uri.parse('http://127.0.0.1:3210'),
        model: 'approved',
      );
      expect(env['ANTHROPIC_API_KEY'], '');
      expect(env['ANTHROPIC_AUTH_TOKEN'], 'lab-local');
      expect(env['ANTHROPIC_DEFAULT_HAIKU_MODEL'], 'approved');
    },
  );
  test(
    'coding proxy cancels a stalled Main stream when local client disconnects',
    () async {
      final main = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final disconnected = Completer<void>();
      addTearDown(() => main.close(force: true));
      main.listen((request) async {
        final upstreamSocket = await request.response.detachSocket(
          writeHeaders: false,
        );
        upstreamSocket.listen(
          (_) {},
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
            upstreamSocket.destroy();
          },
          onError: (Object _) {
            if (!disconnected.isCompleted) disconnected.complete();
            upstreamSocket.destroy();
          },
        );
        upstreamSocket.write(
          'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: ready\n\n',
        );
        await upstreamSocket.flush();
        // Deliberately never finish or emit another chunk.
      });
      final proxy = CodingApiProxy();
      addTearDown(proxy.close);
      final url = await proxy.start(
        upstream: Uri.parse('http://127.0.0.1:${main.port}'),
        readKey: () async => 'key',
      );
      final socket = await Socket.connect('127.0.0.1', url.port);
      final received = Completer<void>();
      socket.listen((bytes) {
        if (utf8.decode(bytes).contains('ready') && !received.isCompleted) {
          received.complete();
        }
      });
      socket.write(
        'POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer lab-local\r\nContent-Length: 0\r\n\r\n',
      );
      await socket.flush();
      await received.future.timeout(const Duration(seconds: 5));
      socket.destroy();
      await disconnected.future.timeout(const Duration(seconds: 5));
      await proxy.close();
    },
  );

  test('coding proxy never forwards the Main key through redirects', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final main = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => target.close(force: true));
    addTearDown(() => main.close(force: true));
    var leaked = false;
    target.listen((request) async {
      leaked = true;
      await request.response.close();
    });
    main.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set(
        'location',
        'http://127.0.0.1:${target.port}/capture',
      );
      await request.response.close();
    });
    final proxy = CodingApiProxy();
    addTearDown(proxy.close);
    final url = await proxy.start(
      upstream: Uri.parse('http://127.0.0.1:${main.port}'),
      readKey: () async => 'private-key',
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(url.resolve('/v1/models'));
    request.followRedirects = false;
    request.headers.set('authorization', 'Bearer lab-local');
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 302);
    expect(leaked, isFalse);
  });

  test(
    'package process environment uses loopback without changing global files',
    () {
      final values = CodingClientSetup.packageEnvironment(
        Uri.parse('http://127.0.0.1:3210'),
      );
      expect(values['HTTPS_PROXY'], 'http://127.0.0.1:3210');
      expect(values['npm_config_proxy'], values['HTTP_PROXY']);
      expect(
        () => CodingClientSetup.packageEnvironment(
          Uri.parse('http://secret@main:80'),
        ),
        throwsArgumentError,
      );
    },
  );
  test('isolated Codex settings contain dummy token and preserve unrelated settings', () async {
    final dir = await Directory.systemTemp.createTemp('coding_setup_');
    addTearDown(() => dir.delete(recursive: true));
    final env = await CodingClientSetup.codex(
      home: dir,
      localUrl: Uri.parse('http://127.0.0.1:1234'),
      model: 'openai/test',
    );
    final file = File('${dir.path}/config.toml');
    final config = await file.readAsString();
    expect(env['CODEX_HOME'], dir.absolute.path);
    expect(env['OPENAI_API_KEY'], 'lab-local');
    expect(env['OPENAI_BASE_URL'], 'http://127.0.0.1:1234/v1');
    expect(config, contains('wire_api = "responses"'));
    expect(config, contains('web_search = "disabled"'));
    expect(config, contains('lab-local'));
    await file.writeAsString('my existing config');
    await expectLater(
      CodingClientSetup.codex(
        home: dir,
        localUrl: Uri.parse('http://127.0.0.1:1234'),
        model: 'x',
      ),
      throwsStateError,
    );
    expect(await file.readAsString(), 'my existing config');
  });
  test(
    'loopback coding proxy injects secret and rejects other routes and tokens',
    () async {
      final main = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => main.close(force: true));
      String? auth;
      main.listen((request) async {
        auth = request.headers.value('authorization');
        request.response.write('ok');
        await request.response.close();
      });
      final proxy = CodingApiProxy();
      addTearDown(proxy.close);
      final url = await proxy.start(
        upstream: Uri.parse('http://127.0.0.1:${main.port}'),
        readKey: () async => 'secret-main-key',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.postUrl(url.resolve('/v1/responses'));
      req.headers.set('authorization', 'Bearer lab-local');
      expect((await req.close()).statusCode, 200);
      expect(auth, 'Bearer secret-main-key');
      final denied = await client.getUrl(url.resolve('/access'));
      denied.headers.set('authorization', 'Bearer lab-local');
      expect((await denied.close()).statusCode, 403);
      final noKey = await client.getUrl(url.resolve('/v1/models'));
      expect((await noKey.close()).statusCode, 403);
    },
  );
}

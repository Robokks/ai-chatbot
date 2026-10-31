import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/local_provider.dart';
import 'package:ai_chatbot/data/local/image_engine.dart';
import 'package:ai_chatbot/data/local/image_gallery.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/host_mcp.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:ai_chatbot/state/image_maker.dart';
import 'package:ai_chatbot/tools/tool_registry.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;

import 'tools_test.dart' show HostBackendFake;

/// A 1×1 PNG.
final tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

class FakeImageBackend implements ImageBackend {
  FakeImageBackend(this.path, this.log, {this.delay = Duration.zero});
  final String path;
  final List<String> log;
  final Duration delay;
  static int running = 0;
  static int maxRunning = 0;

  @override
  Future<MadeImage> generate(String prompt,
      {int? seed, required ImageJob job, void Function(String status, double? fraction)? onProgress}) async {
    running++;
    if (running > maxRunning) maxRunning = running;
    try {
      onProgress?.call('Drawing…', 0.5);
      final stopped = Completer<void>();
      job.onCancel(() {
        if (!stopped.isCompleted) stopped.complete();
      });
      await Future.any([Future<void>.delayed(delay), stopped.future]);
      if (job.cancelled) throw Exception('cancelled');
      log.add('make $prompt');
      return MadeImage(png: tinyPng, width: 512, height: 512, seed: seed ?? 7, elapsed: delay);
    } finally {
      running--;
    }
  }

  @override
  Future<void> dispose() async => log.add('dispose $path');
}

ImageEngineHost fakeEngine(List<String> log,
        {Duration delay = Duration.zero, String? unsupported, Object? loadError}) =>
    ImageEngineHost(
      chat: LocalEngineHost.separate(),
      checkSupport: () async => unsupported,
      loader: (path) async {
        if (loadError != null) throw loadError;
        log.add('load $path');
        return FakeImageBackend(path, log, delay: delay);
      },
    );

class FakeHostImages implements HostImages {
  bool shared = true;
  final made = <String>[];
  @override
  List<String> sharedImageModels() => shared ? const ['local-image/sdxs'] : const [];
  @override
  Future<MadeImage> makeImage(String? model, String prompt, {int? seed, required String device}) async {
    made.add('$device: $prompt');
    return MadeImage(png: tinyPng, width: 512, height: 512, seed: 42, elapsed: Duration.zero);
  }
}

/// Asks for create_image on the first turn, then answers.
class DrawingProvider extends LlmProvider {
  DrawingProvider(ProviderSettings s) : super(settings: s, apiKey: 'k');
  final requests = <ChatRequest>[];

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    requests.add(request);
    final last = request.messages.last;
    if (last.role == Role.tool) {
      yield ChatDelta(text: 'Done: ${last.toolResults.single.text}');
    } else {
      yield ChatDelta(toolCalls: [
        ToolCall(id: 'c1', name: 'phone_create_image', arguments: {'prompt': 'a red fox'}),
      ]);
    }
  }

  @override
  Future<List<String>> listModels() async => [];
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('images');
    FakeImageBackend.running = 0;
    FakeImageBackend.maxRunning = 0;
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  group('catalog', () {
    test('SDXS is the built-in image model, pinned to a revision', () {
      final m = builtInImageModels.single;
      expect(m.isImage, isTrue);
      expect(m.url, contains('/resolve/3144d898d61492f8382ffcabec055733fc5b2a0e/'));
      expect(m.license, isNotNull);
      expect(builtInLocalModels, contains(m));
      final back = LocalModelInfo.fromJson(m.toJson());
      expect(back.kind, LocalModelKind.image);
      expect(LocalModelInfo.fromJson(builtInLocalModels.first.toJson()).kind, LocalModelKind.chat);
    });

    test('an installed image model is not offered as a chat model', () async {
      final storage = await Storage.openAt(dir.path);
      final models = Directory('${dir.path}/m')..createSync();
      final sdxs = builtInImageModels.single;
      File('${models.path}/${sdxs.id}.gguf').writeAsBytesSync([1]);
      final app = AppState(storage, localModels: LocalModelStore(storage, dir: models));
      await app.load();
      expect(app.localModels.installedImageModel, sdxs);
      expect(app.providers[ProviderKind.local]!.models, isEmpty);
      expect(app.hasKey(ProviderKind.local), isFalse);
      expect(app.localModels.chatModels, isNot(contains(sdxs)));
    });
  });

  group('ImageEngineHost', () {
    test('loads once, runs one picture at a time, reloads for another model', () async {
      final log = <String>[];
      final engine = fakeEngine(log, delay: const Duration(milliseconds: 30));
      final a = engine.generate('/m/a.gguf', 'one');
      final b = engine.generate('/m/a.gguf', 'two');
      await Future.wait([a, b]);
      expect(FakeImageBackend.maxRunning, 1);
      await engine.generate('/m/b.gguf', 'three');
      expect(log, ['load /m/a.gguf', 'make one', 'make two', 'dispose /m/a.gguf', 'load /m/b.gguf', 'make three']);
    });

    test('a chat model loading unloads the image model', () async {
      final log = <String>[];
      final chat = LocalEngineHost.separate();
      final engine = ImageEngineHost(
          chat: chat,
          checkSupport: () async => null,
          loader: (p) async => FakeImageBackend(p, log));
      await engine.generate('/m/a.gguf', 'x');
      expect(engine.isLoaded('/m/a.gguf'), isTrue);
      // engineFor fails (no real file) but first asks the image model to go.
      await expectLater(chat.engineFor('/nope.gguf'), throwsA(anything));
      expect(engine.isLoaded('/m/a.gguf'), isFalse);
      expect(log, contains('dispose /m/a.gguf'));
    });

    test('errors are in plain words', () async {
      await expectLater(
        fakeEngine([], unsupported: 'This device can\'t run the image maker.').generate('/m/a.gguf', 'x'),
        throwsA(isA<ImageMakerException>().having((e) => e.message, 'message', contains('can\'t run'))),
      );
      await expectLater(
        fakeEngine([], loadError: Exception('not enough memory: need 1.2 GiB')).generate('/m/a.gguf', 'x'),
        throwsA(isA<ImageMakerException>().having((e) => e.message, 'message', contains('Not enough free memory'))),
      );
      await expectLater(fakeEngine([]).generate('/m/a.gguf', '   '),
          throwsA(isA<ImageMakerException>().having((e) => e.message, 'message', contains('Describe'))));
    });

    test('Stop ends a picture being made', () async {
      final engine = fakeEngine([], delay: const Duration(seconds: 5));
      final job = ImageJob();
      final making = engine.generate('/m/a.gguf', 'slow', job: job);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      job.cancel();
      await expectLater(making, throwsA(isA<ImageMakerException>().having((e) => e.message, 'm', 'Stopped.')));
      expect(engine.busy, isFalse);
    });
  });

  test('gallery saves, reloads and deletes pictures', () async {
    final storage = await Storage.openAt(dir.path);
    final g = ImageGallery(storage, dir: Directory('${dir.path}/img'));
    g.load();
    final a = await g.add(tinyPng, prompt: 'a fox', madeOn: 'This device', seed: 3);
    await g.add(tinyPng, prompt: 'a cat', madeOn: 'PC');
    expect(g.images.map((i) => i.prompt), ['a cat', 'a fox']);
    expect(await g.bytes(a.id), tinyPng);

    final again = ImageGallery(storage, dir: Directory('${dir.path}/img'))..load();
    expect(again.images.last.seed, 3);
    await again.delete(a.id);
    expect(again.images.map((i) => i.prompt), ['a cat']);
    expect(await again.bytes(a.id), isNull);
    expect(() => again.bytes('../x'), throwsArgumentError);
  });

  group('sharing through the home server', () {
    late HostServer host;
    late FakeHostImages images;
    late String key;
    late Uri base;

    setUp(() async {
      images = FakeHostImages();
      host = HostServer(HostBackendFake(),
          loadDevices: () async => [], saveDevices: (_) async {}, images: images);
      await host.start(port: 0, address: InternetAddress.loopbackIPv4);
      base = Uri.parse('http://127.0.0.1:${host.port}');
      key = (await host.createKey('Phone')).key;
    });
    tearDown(() => host.stop());

    Future<http.Response> post(Map<String, dynamic> body, {String? auth}) => http.post(
          base.replace(path: '/v1/images/generations'),
          headers: {'Authorization': 'Bearer ${auth ?? key}', 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        );

    test('OpenAI-style picture API needs a key and returns base64 PNG', () async {
      expect((await post({'prompt': 'a fox'}, auth: 'wrong')).statusCode, 401);

      final models = await http.get(base.replace(path: '/v1/images/models'),
          headers: {'Authorization': 'Bearer $key'});
      expect(jsonDecode(models.body)['data'][0]['id'], 'local-image/sdxs');
      // Chat model list is unchanged.
      final chat = await http.get(base.replace(path: '/v1/models'), headers: {'Authorization': 'Bearer $key'});
      expect(chat.body, isNot(contains('local-image')));

      final res = await post({'prompt': 'a fox', 'n': 1, 'size': '512x512', 'response_format': 'b64_json'});
      expect(res.statusCode, 200, reason: res.body);
      expect(base64Decode(jsonDecode(res.body)['data'][0]['b64_json'] as String), tinyPng);
      expect(images.made, ['Phone: a fox']);
      expect(host.log.first.model, 'Picture');

      expect((await post({'prompt': 'a fox', 'size': '1024x1024'})).statusCode, 400);
      expect((await post({'prompt': ''})).statusCode, 400);
      images.shared = false;
      expect((await post({'prompt': 'a fox'})).statusCode, 404);
    });

    test('a paired device makes pictures on the host', () async {
      final storage = await Storage.openAt(dir.path);
      final phone = AppState(storage,
          localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()),
          imageEngine: fakeEngine([], unsupported: 'No image runtime here.'),
          gallery: ImageGallery(storage, dir: Directory('${dir.path}/img')));
      await phone.load();
      await phone.connectToHost(base, host.pin, 'Big PC', 'Phone');
      await phone.images.refresh();
      expect(phone.images.hostOffers, isTrue);
      expect(phone.images.canMakeHere, isFalse);
      expect(phone.images.target, ImageTarget.homeServer);

      final made = await phone.images.make('a castle');
      expect(made.madeOn, 'Big PC');
      expect(await phone.images.gallery.bytes(made.id), tinyPng);
      expect(images.made, ['Phone: a castle']);

      await phone.disconnectHost();
      expect(phone.images.available, isFalse);
    });

    test('MCP create_image pictures are kept and shown, not sent to the AI', () async {
      final storage = await Storage.openAt(dir.path);
      final gallery = ImageGallery(storage, dir: Directory('${dir.path}/img'));
      final registry = ToolRegistry(storage)
        ..saveImage = ((bytes, mime) async =>
            (await gallery.add(Uint8List.fromList(bytes), prompt: '', madeOn: '')).id);
      await registry.load();
      await registry.addOrUpdate(
        ToolSourceConfig(id: 'h', type: ToolSourceType.mcp, name: 'PC', url: 'http://127.0.0.1:${host.mcpPort}/mcp'),
        secret: key,
      );
      final tool = registry.activeTools().firstWhere((t) => t.name.endsWith('create_image'));
      final r = await registry.execute(ToolCall(id: '1', name: tool.name, arguments: {'prompt': 'a boat'}));
      expect(r.isError, isFalse, reason: r.text);
      expect(r.imageIds, hasLength(1));
      expect(r.text, contains('picture shown to the user'));
      expect(r.text, isNot(contains('iVBOR')));
      expect(await gallery.bytes(r.imageIds.single), tinyPng);
      registry.dispose();
    });
  });

  test('chat create_image tool puts the picture in the reply', () async {
    final storage = await Storage.openAt(dir.path);
    final models = Directory('${dir.path}/m')..createSync();
    File('${models.path}/${builtInImageModels.single.id}.gguf').writeAsBytesSync([1]);
    late DrawingProvider llm;
    final log = <String>[];
    final app = AppState(storage,
        localModels: LocalModelStore(storage, dir: models),
        imageEngine: fakeEngine(log),
        gallery: ImageGallery(storage, dir: Directory('${dir.path}/img')),
        providerFactory: (s, k) => llm = DrawingProvider(s));
    await app.load();
    await app.setKey(ProviderKind.anthropic, 'sk');

    await app.send('draw a fox', []);
    final msgs = app.current!.messages;
    expect(msgs.map((m) => m.role), [Role.user, Role.assistant, Role.tool, Role.assistant]);
    final result = msgs[2].toolResults.single;
    expect(result.isError, isFalse, reason: result.text);
    expect(result.imageIds, hasLength(1));
    expect(log, contains('make a red fox'));
    expect(app.images.gallery.images.single.prompt, 'a red fox');
    expect(llm.requests.first.tools.map((t) => t.name), contains('phone_create_image'));
    // The AI gets text only; the picture id survives a reload.
    expect(llm.requests.last.messages.last.toolResults.single.text, isNot(contains('iVBOR')));
    final saved = storage.loadConversations().single.messages[2].toolResults.single;
    expect(saved.imageIds, result.imageIds);
  });

  test('no image model and no host: the tool is not offered', () async {
    final storage = await Storage.openAt(dir.path);
    final app = AppState(storage,
        localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()),
        imageEngine: fakeEngine([]),
        gallery: ImageGallery(storage, dir: Directory('${dir.path}/img')));
    await app.load();
    expect(app.tools.activeTools().map((t) => t.name), isNot(contains('phone_create_image')));
  });
}

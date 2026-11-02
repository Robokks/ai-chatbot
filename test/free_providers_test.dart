import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/auto_provider.dart';
import 'package:ai_chatbot/data/llm/cloud_images.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/openai_provider.dart';
import 'package:ai_chatbot/data/local/image_engine.dart';
import 'package:ai_chatbot/data/local/image_gallery.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:ai_chatbot/state/image_maker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// Answers, fails before answering, or fails half-way, per provider.
class FakeLlm extends LlmProvider {
  FakeLlm(ProviderSettings s, this.behaviour, this.calls) : super(settings: s, apiKey: 'k');
  final String behaviour;
  final List<String> calls;

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    calls.add('${kind.name}:${request.model}:${request.tools.length}');
    switch (behaviour) {
      case '429':
        throw LlmException('Error 429', statusCode: 429);
      case '401':
        throw LlmException('Error 401', statusCode: 401);
      case 'network':
        throw const SocketException('no route');
      case 'midway':
        yield const ChatDelta(text: 'Half ');
        throw LlmException('Error 500', statusCode: 500);
      default:
        yield ChatDelta(text: 'Hello from ${kind.label}');
    }
  }

  @override
  Future<List<String>> listModels() async => [];
}

final jpeg = img.encodeJpg(img.Image(width: 8, height: 6));

void main() {
  test('free providers are OpenAI-compatible with key links and notes', () {
    final free = [for (final k in ProviderKind.values) if (k.free) k];
    expect(free.length, greaterThanOrEqualTo(13));
    for (final k in free) {
      expect(k.style, k == ProviderKind.gemini ? ApiStyle.gemini : ApiStyle.openai, reason: k.name);
      expect(k.keyUrl, startsWith('https://'), reason: k.name);
      expect(k.freeNote, isNotEmpty, reason: k.name);
      expect(k.models, isNotEmpty, reason: k.name);
      if (k != ProviderKind.freellmapi) expect(k.baseUrl, startsWith('https://'), reason: k.name);
    }
    expect(ProviderKind.cloudflare.needsAccountId, isTrue);
    expect(ProviderKind.cloudflare.baseUrl, contains('{account}'));
    expect(ProviderKind.anthropic.free, isFalse);
  });

  test('a free provider calls its own address with the key', () async {
    late http.Request sent;
    final llm = OpenAiProvider(
      settings: ProviderSettings(kind: ProviderKind.cerebras),
      apiKey: 'csk-1',
      client: MockClient.streaming((req, body) async {
        sent = req as http.Request;
        return http.StreamedResponse(
            Stream.value(utf8.encode('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n')),
            200);
      }),
    );
    final out = await llm
        .streamChat(ChatRequest(model: 'gpt-oss-120b', messages: [Message(role: Role.user, text: 'x')]))
        .map((d) => d.text)
        .join();
    expect(out, 'hi');
    expect(sent.url.toString(), 'https://api.cerebras.ai/v1/chat/completions');
    expect(sent.headers['Authorization'], 'Bearer csk-1');
  });

  group('Free Auto routes', () {
    test('default order, only providers with keys, OpenRouter only with :free models', () {
      final keys = {ProviderKind.groq, ProviderKind.gemini, ProviderKind.openrouter, ProviderKind.cerebras};
      var routes = resolveAutoRoutes(null,
          hasKey: keys.contains, modelsFor: (k) => List.of(k.models));
      expect(routes.map((r) => r.kind), [ProviderKind.gemini, ProviderKind.groq, ProviderKind.cerebras]);

      routes = resolveAutoRoutes(null,
          hasKey: keys.contains,
          modelsFor: (k) => k == ProviderKind.openrouter ? ['openai/gpt-5', 'qwen/qwen3:free'] : List.of(k.models));
      expect(routes.firstWhere((r) => r.kind == ProviderKind.openrouter).model, 'qwen/qwen3:free');
    });

    test('the saved order and choices are kept; providers without keys drop out', () {
      final saved = encodeAutoRoutes([
        AutoRoute(kind: ProviderKind.cerebras, model: 'qwen-3-32b'),
        AutoRoute(kind: ProviderKind.groq, model: 'llama', enabled: false),
        AutoRoute(kind: ProviderKind.mistral, model: 'm'),
      ]);
      final routes = resolveAutoRoutes(saved,
          hasKey: {ProviderKind.cerebras, ProviderKind.groq, ProviderKind.gemini}.contains,
          modelsFor: (k) => List.of(k.models));
      expect(routes.map((r) => '${r.kind.name}:${r.model}:${r.enabled}'),
          ['cerebras:qwen-3-32b:true', 'groq:llama:false', 'gemini:${ProviderKind.gemini.models.first}:true']);
    });
  });

  group('Free Auto answering', () {
    late List<String> calls;
    late AutoCooldowns cool;
    AutoProvider auto(Map<ProviderKind, String> behaviour) => AutoProvider(
          settings: ProviderSettings(kind: ProviderKind.auto),
          routes: [for (final k in behaviour.keys) AutoRoute(kind: k, model: '${k.name}-m')],
          providerFor: (k) => FakeLlm(ProviderSettings(kind: k), behaviour[k]!, calls),
          cooldowns: cool,
        );
    setUp(() {
      calls = [];
      cool = AutoCooldowns();
    });
    final req = ChatRequest(model: 'auto', messages: [Message(role: Role.user, text: 'hi')], tools: const [
      ToolSpec(name: 't', description: 'd', inputSchema: {}, sourceId: 's', sourceLabel: 'S'),
    ]);

    test('moves on when a provider is at its limit, and rests it', () async {
      final p = auto({ProviderKind.groq: '429', ProviderKind.cerebras: 'ok'});
      final deltas = await p.streamChat(req).toList();
      expect(deltas.map((d) => d.text).join(), 'Hello from Cerebras');
      expect(deltas.any((d) => d.status == 'Trying Cerebras…'), isTrue);
      expect(deltas.firstWhere((d) => d.servedBy != null).servedBy, (ProviderKind.cerebras, 'cerebras-m'));
      expect(calls, ['groq:groq-m:1', 'cerebras:cerebras-m:1'], reason: 'tools passed through');
      expect(cool.until(ProviderKind.groq), isNotNull);
      expect(cool.lastUsed, (ProviderKind.cerebras, 'cerebras-m'));

      calls.clear();
      await p.streamChat(req).toList();
      expect(calls, ['cerebras:cerebras-m:1'], reason: 'Groq is resting');
    });

    test('network errors and bad keys also move on', () async {
      final p = auto({ProviderKind.gemini: 'network', ProviderKind.mistral: '401', ProviderKind.zai: 'ok'});
      expect((await p.streamChat(req).toList()).map((d) => d.text).join(), 'Hello from Z.ai');
      expect(cool.until(ProviderKind.mistral), isNotNull);
      expect(cool.until(ProviderKind.gemini), isNull);
    });

    test('never mixes two models: a failure after the answer started is reported', () async {
      final p = auto({ProviderKind.groq: 'midway', ProviderKind.cerebras: 'ok'});
      await expectLater(p.streamChat(req).toList(), throwsA(isA<LlmException>()));
      expect(calls, ['groq:groq-m:1']);
    });

    test('when all fail, the message says why for each', () async {
      final p = auto({ProviderKind.groq: '429', ProviderKind.cerebras: '401'});
      await expectLater(
          p.streamChat(req).toList(),
          throwsA(isA<LlmException>().having((e) => e.message, 'message',
              allOf(contains('Groq: limit reached'), contains('Cerebras: key not accepted')))));
      // Everyone resting: the one back soonest is still tried next time.
      calls.clear();
      await expectLater(p.streamChat(req).toList(), throwsA(isA<LlmException>()));
      expect(calls, hasLength(1));
    });
  });

  group('in the app', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('free'));
    tearDown(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    Future<AppState> app() async {
      final storage = await Storage.openAt(dir.path);
      final s = AppState(storage,
          localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()),
          gallery: ImageGallery(storage, dir: Directory('${dir.path}/img')),
          imageEngine: ImageEngineHost(checkSupport: () async => 'no runtime here'),
          providerFactory: (settings, key) => FakeLlm(
              settings, settings.kind == ProviderKind.groq ? '429' : 'ok', <String>[]));
      await s.load();
      return s;
    }

    test('Free Auto appears with a free key and the reply shows who answered', () async {
      final s = await app();
      expect(s.hasKey(ProviderKind.auto), isFalse);
      await s.setKey(ProviderKind.groq, 'gsk');
      await s.setKey(ProviderKind.cerebras, 'csk');
      expect(s.hasKey(ProviderKind.auto), isTrue);
      await s.selectModel(ProviderKind.auto, 'auto');
      await s.send('hi', []);
      final reply = s.current!.messages.last;
      expect(reply.error, isNull);
      expect(reply.text, 'Hello from Cerebras');
      expect(reply.provider, ProviderKind.cerebras);
      expect(reply.model, ProviderKind.cerebras.models.first);
    });

    test('Cloudflare needs its Account ID before it counts as set up', () async {
      final s = await app();
      await s.setKey(ProviderKind.cloudflare, 'cf-token');
      expect(s.hasKey(ProviderKind.cloudflare), isFalse);
      await s.updateProviderSettings(ProviderSettings(
          kind: ProviderKind.cloudflare,
          baseUrl: ProviderKind.cloudflare.baseUrl.replaceFirst('{account}', 'abc123')));
      expect(s.hasKey(ProviderKind.cloudflare), isTrue);
      expect(s.images.targets.first, ImageTarget.cloudflare);
      expect(s.images.target, ImageTarget.cloudflare);
    });
  });

  group('free online pictures', () {
    test('Cloudflare FLUX: right address, base64 answer, stored as PNG', () async {
      late http.Request sent;
      final c = CloudImageClient(
          client: () => MockClient((req) async {
                sent = req;
                return http.Response(jsonEncode({'result': {'image': base64Encode(jpeg)}}), 200);
              }));
      final made = await c.cloudflare(
          'https://api.cloudflare.com/client/v4/accounts/abc/ai/v1', 'tok', 'a fox');
      expect(sent.url.toString(),
          'https://api.cloudflare.com/client/v4/accounts/abc/ai/run/@cf/black-forest-labs/flux-1-schnell');
      expect(sent.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(sent.body)['prompt'], 'a fox');
      expect(made.png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect((made.width, made.height), (8, 6));
    });

    test('Hugging Face FLUX: raw image bytes', () async {
      late http.Request sent;
      final c = CloudImageClient(
          client: () => MockClient((req) async {
                sent = req;
                return http.Response.bytes(jpeg, 200, headers: {'content-type': 'image/jpeg'});
              }));
      final made = await c.huggingFace('hf_x', 'a cat');
      expect(sent.url.path, '/hf-inference/models/black-forest-labs/FLUX.1-schnell');
      expect(jsonDecode(sent.body)['inputs'], 'a cat');
      expect(made.width, 8);
    });

    test('limits and bad keys get plain words', () async {
      CloudImageClient answering(int status) =>
          CloudImageClient(client: () => MockClient((_) async => http.Response('{}', status)));
      await expectLater(answering(429).huggingFace('k', 'x'),
          throwsA(isA<ImageMakerException>().having((e) => e.message, 'm', contains('limit is used up'))));
      await expectLater(answering(403).cloudflare('https://h/accounts/a/ai/v1', 'k', 'x'),
          throwsA(isA<ImageMakerException>().having((e) => e.message, 'm', contains('Workers AI'))));
      await expectLater(answering(503).huggingFace('k', 'x'),
          throwsA(isA<ImageMakerException>().having((e) => e.message, 'm', contains('Try again in a minute'))));
    });
  });

  test('pictures made online are kept in the gallery with where they came from', () async {
    final dir = Directory.systemTemp.createTempSync('cfmake');
    addTearDown(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });
    final storage = await Storage.openAt(dir.path);
    final s = AppState(storage,
        localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()),
        gallery: ImageGallery(storage, dir: Directory('${dir.path}/img')));
    await s.load();
    final maker = ImageMaker(s,
        gallery: s.images.gallery,
        engine: ImageEngineHost(checkSupport: () async => 'none'),
        cloud: CloudImageClient(
            client: () => MockClient((_) async => http.Response.bytes(Uint8List.fromList(jpeg), 200))));
    await s.setKey(ProviderKind.huggingface, 'hf_x');
    expect(maker.target, ImageTarget.huggingface);
    final g = await maker.make('a red fox');
    expect(g.madeOn, 'Hugging Face FLUX');
    expect(g.width, 8);
  });
}

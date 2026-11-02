import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/core/theme.dart';
import 'package:ai_chatbot/data/llm/auto_provider.dart';
import 'package:ai_chatbot/data/llm/home_images.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/local/image_engine.dart';
import 'package:ai_chatbot/data/local/image_gallery.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/local/picture_reader.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/features/setup/setup_wizard.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:ai_chatbot/state/attachment_prep.dart';
import 'package:ai_chatbot/state/image_maker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

final png = img.encodePng(img.Image(width: 4, height: 3));

Attachment photo() =>
    Attachment(name: 'p.png', mimeType: 'image/png', kind: AttachmentKind.image, size: png.length, bytes: png);

/// Records requests; [failing] providers answer 429; the picture reader
/// prompt gets "READ".
class Recorder extends LlmProvider {
  Recorder(ProviderSettings s, this.log, this.failing) : super(settings: s, apiKey: 'k');
  final List<String> log;
  final Set<ProviderKind> failing;

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    final last = request.messages.last;
    final reading = last.text == pictureReadInstructions;
    final pics = last.attachments.where((a) => a.kind == AttachmentKind.image);
    log.add('${kind.name}${reading ? ':read' : ''}${pics.any((a) => a.text == null) ? ':picture' : ''}'
        '${pics.any((a) => a.text != null) ? ':text' : ''}');
    if (failing.contains(kind)) throw LlmException('Error 429', statusCode: 429);
    yield ChatDelta(text: reading ? 'READ' : 'ok from ${kind.label}');
  }

  @override
  Future<List<String>> listModels() async => List.of(kind.models);
}

void main() {
  late Directory dir;
  late List<String> log;
  late Set<ProviderKind> failing;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('online');
    log = [];
    failing = {};
  });
  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  Future<AppState> app() async {
    final storage = await Storage.openAt(dir.path);
    final s = AppState(storage,
        localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()),
        gallery: ImageGallery(storage, dir: Directory('${dir.path}/img')),
        imageEngine: ImageEngineHost(checkSupport: () async => 'none'),
        providerFactory: (settings, key) => Recorder(settings, log, failing));
    await s.load();
    return s;
  }

  group('online first', () {
    test('the first free key switches to Free Auto; a paid model with a key is kept', () async {
      var s = await app();
      expect(s.provider, ProviderKind.anthropic);
      await s.setKey(ProviderKind.groq, 'gsk');
      expect(s.provider, ProviderKind.auto);
      expect(s.storage.getSetting('provider'), 'auto');

      await s.setKey(ProviderKind.anthropic, 'sk');
      await s.selectModel(ProviderKind.anthropic, 'claude-sonnet-5-5');
      await Hive.close();
      s = await app();
      expect(s.provider, ProviderKind.anthropic, reason: 'chosen and usable');
    });

    test('Free Auto sends pictures to a provider that can see, without reading them first', () async {
      final s = await app();
      await s.setKey(ProviderKind.groq, 'g');
      await s.setKey(ProviderKind.gemini, 'm');
      await s.send('what is this?', [photo()]);
      expect(log, ['gemini:picture']);
      expect(s.current!.messages.last.provider, ProviderKind.gemini);
    });

    test('when no provider that can see works, the pictures are read and anyone answers', () async {
      final s = await app();
      await s.setKey(ProviderKind.groq, 'g');
      await s.setKey(ProviderKind.gemini, 'm');
      await s.reader.setAlways(ProviderKind.gemini, true);
      failing = {ProviderKind.gemini};
      await s.send('what is this?', [photo()]);
      // Gemini fails to answer; reading also fails on Gemini (limit), so the
      // picture stays unread and Groq answers with a note.
      expect(log.first, 'gemini:picture');
      expect(log.last, startsWith('groq'));
      expect(s.current!.messages.last.text, 'ok from Groq');
    });

    test('free online readers come before paid ones', () {
      expect(AttachmentPrep.cloudReaders.indexOf(ProviderKind.gemini),
          lessThan(AttachmentPrep.cloudReaders.indexOf(ProviderKind.anthropic)));
      expect(AttachmentPrep.cloudReaders.indexOf(ProviderKind.mistral),
          lessThan(AttachmentPrep.cloudReaders.indexOf(ProviderKind.openai)));
    });
  });

  group('more providers', () {
    test('Together and Chutes are used by Free Auto only with free models', () {
      expect(isFreeModel(ProviderKind.together, 'meta-llama/Llama-3.3-70B-Instruct-Turbo-Free'), isTrue);
      expect(isFreeModel(ProviderKind.together, 'meta-llama/Llama-3.3-70B-Instruct-Turbo'), isFalse);
      expect(isFreeModel(ProviderKind.chutes, 'deepseek-ai/DeepSeek-V3:free'), isTrue);
      expect(defaultAutoModel(ProviderKind.together, ['a', 'b-Free']), 'b-Free');
      expect(defaultAutoModel(ProviderKind.cerebras, ['x']), 'x');
      for (final k in [ProviderKind.chutes, ProviderKind.together, ProviderKind.scaleway, ProviderKind.ovh,
        ProviderKind.qwen, ProviderKind.deepinfra]) {
        expect(k.free, isTrue, reason: k.name);
        expect(defaultAutoOrder, contains(k));
      }
    });

    test('Together FLUX makes free pictures through the OpenAI-style API', () async {
      late http.Request sent;
      final s = await app();
      await s.setKey(ProviderKind.together, 'tg');
      final maker = ImageMaker(s,
          gallery: s.images.gallery,
          engine: ImageEngineHost(checkSupport: () async => 'none'),
          home: HomeImageClient(
              client: () => MockClient((req) async {
                    sent = req;
                    return http.Response(jsonEncode({
                      'data': [
                        {'b64_json': base64Encode(png)},
                      ],
                    }), 200);
                  })));
      expect(maker.target, ImageTarget.together);
      final g = await maker.make('a boat');
      expect(sent.url.toString(), 'https://api.together.xyz/v1/images/generations');
      final body = jsonDecode(sent.body) as Map;
      expect(body['model'], togetherFluxModel);
      expect(body.containsKey('size'), isFalse);
      expect(g.madeOn, 'Together FLUX');
      expect((g.width, g.height), (4, 3));
    });
  });

  group('setup wizard', () {
    Future<void> show(WidgetTester tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late AppState s;
      await tester.runAsync(() async => s = await app());
      await tester.pumpWidget(AppScope(
        state: s,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(onPressed: () => openSetupWizard(context), child: const Text('open')),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('paste a key, it is checked, Done picks Free Auto', (tester) async {
      await show(tester);
      final s = AppScope.of(tester.element(find.byType(SetupWizard)));
      expect(shouldAutoOpenSetup(s), isTrue);
      expect(find.text('1. Groq: fast free chat'), findsOneWidget);
      expect(find.text('Add one key to finish'), findsOneWidget);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': ' gsk_test '};
        return null;
      });
      await tester.runAsync(() async {
        await tester.tap(find.text('Paste').first);
        for (var i = 0; i < 50 && !s.hasKey(ProviderKind.groq); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(s.keyFor(ProviderKind.groq), 'gsk_test');
      expect(find.textContaining('Works'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('Done: start chatting with Free Auto'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(s.provider, ProviderKind.auto);
      expect(s.storage.getSetting(setupDoneKey), 'done');
      expect(shouldAutoOpenSetup(s), isFalse);
    });

    testWidgets('skip is remembered', (tester) async {
      await show(tester);
      final s = AppScope.of(tester.element(find.byType(SetupWizard)));
      await tester.runAsync(() async {
        await tester.tap(find.text('Skip'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.byType(SetupWizard), findsNothing);
      expect(shouldAutoOpenSetup(s), isFalse);
    });
  });
}

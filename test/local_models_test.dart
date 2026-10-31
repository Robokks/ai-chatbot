import 'dart:async';
import 'dart:io';

import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/llm/local_provider.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llamadart/llamadart.dart';

const _model = LocalModelInfo(
    id: 'tiny', name: 'Tiny', url: 'https://example.com/tiny.gguf', sizeMb: 1, ramGb: 1);

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('models'));
  tearDown(() async => dir.delete(recursive: true));

  group('LocalModelStore', () {
    test('downloads to <id>.gguf and lists it as installed', () async {
      final client = MockClient.streaming((req, _) async {
        expect(req.url.toString(), _model.url);
        return http.StreamedResponse(
            Stream.fromIterable([List.filled(1000, 1), List.filled(500, 2)]), 200,
            contentLength: 1500);
      });
      final store = LocalModelStore(null, dir: dir, client: client);
      await store.load();
      await store.download(_model);

      final file = File('${dir.path}/tiny.gguf');
      expect(await file.length(), 1500);
      expect(File('${dir.path}/tiny.gguf.part').existsSync(), isFalse);
      expect(store.installed, {'tiny'});
      expect(store.progress, isEmpty);

      final reloaded = LocalModelStore(null, dir: dir);
      await reloaded.load();
      expect(reloaded.installed, {'tiny'});

      await store.delete('tiny');
      expect(file.existsSync(), isFalse);
      expect(store.installed, isEmpty);
    });

    test('cancel stops the download and leaves no file', () async {
      final chunks = StreamController<List<int>>();
      final client = MockClient.streaming(
          (_, _) async => http.StreamedResponse(chunks.stream, 200, contentLength: 100));
      final store = LocalModelStore(null, dir: dir, client: client);
      final future = store.download(_model);
      await Future<void>.delayed(Duration.zero);
      chunks.add([1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      store.cancel('tiny');
      chunks.add([4]);
      await expectLater(future, throwsA(isA<DownloadCancelled>()));
      await chunks.close();
      expect(dir.listSync(), isEmpty);
      expect(store.installed, isEmpty);
    });

    test('HTTP errors are reported and clean up', () async {
      final client = MockClient.streaming(
          (_, _) async => http.StreamedResponse(const Stream.empty(), 401));
      final store = LocalModelStore(null, dir: dir, client: client);
      await expectLater(store.download(_model),
          throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('login'))));
      expect(dir.listSync(), isEmpty);
    });

    test('verifies the SHA-256 when one is pinned', () async {
      http.StreamedResponse body() =>
          http.StreamedResponse(Stream.value('hello'.codeUnits), 200, contentLength: 5);
      final store = LocalModelStore(null, dir: dir, client: MockClient.streaming((_, _) async => body()));
      // sha256("hello")
      const good = LocalModelInfo(
          id: 'ok', name: 'ok', url: 'https://example.com/ok.gguf', sizeMb: 1, ramGb: 1,
          sha256: '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
      await store.download(good);
      expect(store.installed, contains('ok'));

      const bad = LocalModelInfo(
          id: 'bad', name: 'bad', url: 'https://example.com/bad.gguf', sizeMb: 1, ramGb: 1,
          sha256: '0000000000000000000000000000000000000000000000000000000000000000');
      await expectLater(store.download(bad), throwsA(isA<ChecksumMismatch>()));
      expect(File('${dir.path}/bad.gguf').existsSync(), isFalse);
      expect(File('${dir.path}/bad.gguf.part').existsSync(), isFalse);
    });

    test('parses hf:// and https links', () {
      final hf = LocalModelInfo.fromLink('hf://LiquidAI/LFM2-1.2B-GGUF/LFM2-1.2B-Q4_K_M.gguf');
      expect(hf.url,
          'https://huggingface.co/LiquidAI/LFM2-1.2B-GGUF/resolve/main/LFM2-1.2B-Q4_K_M.gguf');
      expect(hf.id, 'LFM2-1.2B-Q4_K_M');
      expect(() => LocalModelInfo.fromLink('https://example.com/model.bin'),
          throwsFormatException);
    });

    test('built-in list leads with Liquid AI LFM models', () {
      expect(builtInLocalModels.first.name, startsWith('LFM2'));
      expect(builtInLocalModels.map((m) => m.id).toSet(), hasLength(builtInLocalModels.length));
    });
  });

  group('LocalProvider.toLlamaMessages', () {
    test('maps roles, system prompt and text attachments', () {
      final msgs = LocalProvider.toLlamaMessages(ChatRequest(
        model: 'tiny',
        systemPrompt: 'Be brief',
        messages: [
          Message(role: Role.user, text: 'Summarize', attachments: [
            Attachment(
                name: 'n.txt', mimeType: 'text/plain', kind: AttachmentKind.text, size: 5, text: 'notes'),
          ]),
          Message(role: Role.assistant, text: 'Done.'),
          Message(role: Role.user, text: 'Thanks'),
        ],
      ));
      expect(msgs.map((m) => m.role), [
        LlamaChatRole.system,
        LlamaChatRole.user,
        LlamaChatRole.assistant,
        LlamaChatRole.user,
      ]);
      expect(msgs[1].content, contains('notes'));
      expect(msgs[1].content, contains('Summarize'));
    });

    test('drops the oldest turns when history is too long', () {
      final long = 'x' * 3000;
      final msgs = LocalProvider.toLlamaMessages(ChatRequest(model: 'tiny', messages: [
        Message(role: Role.user, text: long),
        Message(role: Role.assistant, text: long),
        Message(role: Role.user, text: long),
        Message(role: Role.assistant, text: long),
        Message(role: Role.user, text: 'latest'),
      ]));
      expect(msgs.first.role, LlamaChatRole.user);
      expect(msgs.last.content, 'latest');
      expect(msgs.length, lessThan(5));
    });
  });
}

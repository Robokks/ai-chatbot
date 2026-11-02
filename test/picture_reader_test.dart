import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/local/picture_reader.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:ai_chatbot/state/attachment_prep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;

/// A 1×1 PNG.
final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

Attachment photo([String name = 'receipt.jpg']) =>
    Attachment(name: name, mimeType: 'image/png', kind: AttachmentKind.image, size: png.length, bytes: png);

/// Records what each provider is asked. Claude, used as a cloud reader,
/// answers with the text it "read".
class RecordingProvider extends LlmProvider {
  RecordingProvider(ProviderSettings s, this.log) : super(settings: s, apiKey: 'k');
  final List<(ProviderKind, ChatRequest)> log;

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    log.add((kind, request));
    if (request.messages.single.text == pictureReadInstructions) {
      yield const ChatDelta(text: 'CLOUD READ: total 17');
    } else {
      yield const ChatDelta(text: 'ok');
    }
  }

  @override
  Future<List<String>> listModels() async => [];
}

void main() {
  late Directory dir;
  late Directory models;
  late List<(ProviderKind, ChatRequest)> log;
  late List<String> reads;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('reader');
    models = Directory('${dir.path}/m')..createSync();
    log = [];
    reads = [];
  });
  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  void installReader({bool projector = true}) {
    final m = builtInVisionModels.first;
    File('${models.path}/${m.id}.gguf').writeAsBytesSync([1]);
    if (projector) File('${models.path}/${m.id}.mmproj.gguf').writeAsBytesSync([1]);
  }

  Future<AppState> app(
      {Future<(List<Uint8List>, int)> Function(Uint8List, int)? renderPdf}) async {
    final storage = await Storage.openAt(dir.path);
    final s = AppState(storage,
        localModels: LocalModelStore(storage, dir: models),
        providerFactory: (settings, key) => RecordingProvider(settings, log),
        pictureReader: LocalPictureReader(run: (model, projector, image, instructions) async {
          expect(model, endsWith('.gguf'));
          expect(projector, endsWith('.mmproj.gguf'));
          reads.add(instructions);
          return 'TOTAL 42 EUR';
        }),
        renderPdf: renderPdf);
    await s.load();
    return s;
  }

  ChatRequest lastChat(ProviderKind k) =>
      log.lastWhere((e) => e.$1 == k && e.$2.messages.last.text != pictureReadInstructions).$2;

  String sentText(ChatRequest r) => inlineTextAttachments(r.messages.last, includePdf: true, includeImages: true);

  test('a vision model needs its projector to count as installed', () async {
    installReader(projector: false);
    var s = await app();
    expect(s.localModels.installedVisionModel, isNull);
    expect(s.localModels.interrupted, contains(builtInVisionModels.first.id));
    await Hive.close();
    installReader();
    s = await app();
    expect(s.localModels.installedVisionModel, builtInVisionModels.first);
    // Picture readers are not chat models.
    expect(s.providers[ProviderKind.local]!.models, isEmpty);
  });

  test('models that can\'t see get the picture read on this device, once', () async {
    installReader();
    final s = await app();
    await s.setKey(ProviderKind.deepseek, 'k');
    await s.selectModel(ProviderKind.deepseek, ProviderKind.deepseek.models.first);
    await s.send('What is the total?', [photo()]);
    final text = sentText(lastChat(ProviderKind.deepseek));
    expect(text, contains('<image name="receipt.jpg">'));
    expect(text, contains('TOTAL 42 EUR'));
    expect(text, contains('on this device'));
    expect(reads, hasLength(1));

    await s.send('And the tax?', []);
    expect(reads, hasLength(1), reason: 'read once, kept with the chat');
    final saved = s.storage.loadConversations().single.messages.first.attachments.single;
    expect(saved.text, contains('TOTAL 42 EUR'));
  });

  test('models that can see still get the real picture', () async {
    installReader();
    final s = await app();
    await s.setKey(ProviderKind.anthropic, 'k');
    await s.send('What is this?', [photo()]);
    final a = lastChat(ProviderKind.anthropic).messages.last.attachments.single;
    expect(a.bytes, isNotNull);
    expect(a.text, isNull);
    expect(reads, isEmpty);
  });

  test('without a reader, it asks before using a cloud key: Yes, Always, No', () async {
    final s = await app();
    await s.setKey(ProviderKind.anthropic, 'k');
    await s.setKey(ProviderKind.groq, 'k');
    await s.selectModel(ProviderKind.groq, ProviderKind.groq.models.first);

    Future<void> answer(CloudReadChoice c) async {
      for (var i = 0; i < 200 && s.pendingPictureRead == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(s.pendingPictureRead!.provider, ProviderKind.anthropic);
      s.answerPictureRead(c);
    }

    var sending = s.send('Read it', [photo('a.jpg')]);
    await answer(CloudReadChoice.yes);
    await sending;
    expect(sentText(lastChat(ProviderKind.groq)), contains('CLOUD READ: total 17'));
    expect(sentText(lastChat(ProviderKind.groq)), contains('(Read by Claude)'));

    sending = s.send('No thanks', [photo('b.jpg')]);
    await answer(CloudReadChoice.no);
    await sending;
    expect(sentText(lastChat(ProviderKind.groq)), contains('could not be read'));
    expect(sentText(lastChat(ProviderKind.groq)), contains('picture reader'));

    sending = s.send('Always', [photo('c.jpg')]);
    await answer(CloudReadChoice.always);
    await sending;
    expect(s.reader.alwaysAllowed, {ProviderKind.anthropic});
    await s.send('Again', [photo('d.jpg')]);
    expect(s.pendingPictureRead, isNull);
    expect(sentText(lastChat(ProviderKind.groq)), contains('CLOUD READ'));
  });

  test('scanned PDFs are read page by page for models without PDF support', () async {
    installReader();
    final s = await app(renderPdf: (pdf, max) async => ([png, png], 3));
    await s.setKey(ProviderKind.deepseek, 'k');
    await s.selectModel(ProviderKind.deepseek, ProviderKind.deepseek.models.first);
    final scan = Attachment(
        name: 'scan.pdf', mimeType: 'application/pdf', kind: AttachmentKind.pdf, size: 3,
        bytes: Uint8List.fromList([1, 2, 3]));
    await s.send('Summarise', [scan]);
    final text = sentText(lastChat(ProviderKind.deepseek));
    expect(text, contains('<file name="scan.pdf">'));
    expect(text, contains('--- Page 2 ---\nTOTAL 42 EUR'));
    expect(text, contains('only the first 2 of 3 pages'));
    expect(reads, hasLength(2));
  });

  test('the home server reads pictures for its own models', () async {
    final seen = <ChatRequest>[];
    final host = HostServer(_Backend(seen),
        loadDevices: () async => [],
        saveDevices: (_) async {},
        prepareAttachments: (messages, kind) async {
          for (final a in messages.last.attachments) {
            if (!kind.images) a.text = 'HOST READ';
          }
        });
    await host.start(port: 0, address: InternetAddress.loopbackIPv4, mcp: false);
    final key = (await host.createKey('Phone')).key;
    final res = await http.post(Uri.parse('http://127.0.0.1:${host.port}/v1/chat/completions'),
        headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'local/LFM2-1.2B-Q4_K_M',
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'what is it?'},
                {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,${base64Encode(png)}'}},
              ],
            },
          ],
        }));
    expect(res.statusCode, 200, reason: res.body);
    expect(inlineTextAttachments(seen.single.messages.last, includePdf: true, includeImages: true),
        contains('HOST READ'));
    await host.stop();
  });
}

class _Backend implements HostBackend {
  _Backend(this.seen);
  final List<ChatRequest> seen;
  @override
  String get deviceName => 'PC';
  @override
  List<SharedModel> sharedModels() => const [SharedModel(ProviderKind.local, 'LFM2-1.2B-Q4_K_M')];
  @override
  LlmProvider providerFor(ProviderKind kind) => _Seen(kind, seen);
}

class _Seen extends LlmProvider {
  _Seen(ProviderKind k, this.seen) : super(settings: ProviderSettings(kind: k), apiKey: '');
  final List<ChatRequest> seen;
  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    seen.add(request);
    yield const ChatDelta(text: 'fine');
  }

  @override
  Future<List<String>> listModels() async => [];
}

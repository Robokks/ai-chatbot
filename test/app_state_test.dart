import 'dart:typed_data';

import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

class FakeProvider extends LlmProvider {
  FakeProvider(ProviderSettings s, this.reply) : super(settings: s, apiKey: 'k');
  final List<ChatDelta> reply;
  ChatRequest? last;

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) {
    last = request;
    return Stream.fromIterable(reply);
  }

  @override
  Future<List<String>> listModels() async => ['m'];
}

void main() {
  late Directory dir;
  late Storage storage;
  late FakeProvider fake;
  late AppState state;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chat_test');
    storage = await Storage.openAt(dir.path);
    state = AppState(storage, providerFactory: (s, k) {
      return fake = FakeProvider(s, const [ChatDelta(text: 'Hello '), ChatDelta(text: 'there')]);
    });
    await state.load();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('without a key, shows a helpful error', () async {
    await state.send('Hi', []);
    final reply = state.current!.messages.last;
    expect(reply.role, Role.assistant);
    expect(reply.error, contains('API key'));
  });

  test('send streams the reply, titles and persists the chat', () async {
    await state.setKey(ProviderKind.anthropic, 'sk-test');
    await state.send('What is Flutter?', []);

    final c = state.current!;
    expect(c.title, 'What is Flutter?');
    expect(c.messages.map((m) => m.role), [Role.user, Role.assistant]);
    expect(c.messages.last.text, 'Hello there');
    expect(state.isStreaming, isFalse);
    expect(fake.last!.messages, hasLength(1));

    final reloaded = storage.loadConversations();
    expect(reloaded.single.messages.last.text, 'Hello there');
    expect(await storage.readKey(ProviderKind.anthropic), 'sk-test');
  });

  test('attachment bytes are stored separately and rehydrated', () async {
    await state.setKey(ProviderKind.anthropic, 'sk-test');
    final a = Attachment(
        name: 'x.png', mimeType: 'image/png', kind: AttachmentKind.image, size: 1,
        bytes: Uint8List.fromList([9]));
    await state.send('', [a]);
    final loaded = storage.loadConversations().single;
    expect(loaded.messages.first.attachments.single.bytes, isNull);
    storage.hydrate(loaded);
    expect(loaded.messages.first.attachments.single.bytes, [9]);
  });

  test('regenerate replaces the last reply; edit truncates history', () async {
    await state.setKey(ProviderKind.anthropic, 'sk-test');
    await state.send('one', []);
    await state.send('two', []);
    await state.regenerate();
    expect(state.current!.messages, hasLength(4));

    await state.editAndResend(state.current!.messages.first, 'uno');
    final msgs = state.current!.messages;
    expect(msgs.map((m) => m.text), ['uno', 'Hello there']);
  });

  test('delete removes the conversation', () async {
    await state.setKey(ProviderKind.anthropic, 'sk-test');
    await state.send('bye', []);
    await state.delete(state.current!);
    expect(state.current, isNull);
    expect(storage.loadConversations(), isEmpty);
  });
}

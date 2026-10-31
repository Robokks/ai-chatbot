import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/discovery.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

class EchoProvider extends LlmProvider {
  EchoProvider(ProviderKind kind) : super(settings: ProviderSettings(kind: kind), apiKey: '');

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    for (final w in ['Hello ', 'from ', 'the ', 'host']) {
      yield ChatDelta(text: w);
    }
    yield ChatDelta(usage: UsageStats(inputTokens: 5, outputTokens: 4));
  }

  @override
  Future<List<String>> listModels() async => [];
}

class Backend implements HostBackend {
  @override
  String get deviceName => 'Old phone';
  @override
  List<SharedModel> sharedModels() =>
      const [SharedModel(ProviderKind.local, 'LFM2-1.2B-Q4_K_M')];
  @override
  LlmProvider providerFor(ProviderKind kind) => EchoProvider(kind);
}

void main() {
  late HostServer host;
  late Uri base;
  late Directory dir;
  late AppState laptop;

  setUp(() async {
    host = HostServer(Backend(), loadDevices: () async => [], saveDevices: (_) async {});
    await host.start(port: 0, address: InternetAddress.loopbackIPv4);
    base = Uri.parse('http://127.0.0.1:${host.port}');
    dir = await Directory.systemTemp.createTemp('laptop');
    final storage = await Storage.openAt(dir.path);
    laptop = AppState(storage,
        localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()));
    await laptop.load();
  });

  tearDown(() async {
    await host.stop();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('address parsing', () {
    expect(parseHostAddress('192.168.1.5').toString(), 'http://192.168.1.5:8484');
    expect(parseHostAddress(' 192.168.1.5:9000 ').port, 9000);
    expect(parseHostAddress('http://pc.local:8484').host, 'pc.local');
    expect(() => parseHostAddress(''), throwsFormatException);
  });

  test('checkHost names a host and rejects other servers', () async {
    expect(await checkHost(base), 'Old phone');
    await expectLater(checkHost(Uri.parse('http://127.0.0.1:1')), throwsA(isA<PairingException>()));
  });

  test('wrong PIN gives a clear error', () async {
    await expectLater(
      laptop.connectToHost(base, '000000', 'Old phone', 'Laptop'),
      throwsA(isA<PairingException>().having((e) => e.message, 'message', contains('Wrong PIN'))),
    );
    expect(laptop.hasKey(ProviderKind.network), isFalse);
  });

  test('pair, list models and chat through the host', () async {
    await laptop.connectToHost(base, host.pin, 'Old phone', 'Laptop');
    expect(laptop.hasKey(ProviderKind.network), isTrue);
    expect(laptop.connectedHostName, 'Old phone');
    expect(laptop.providers[ProviderKind.network]!.models, ['local/LFM2-1.2B-Q4_K_M']);
    expect(laptop.provider, ProviderKind.network);
    expect(host.devices.single.name, 'Laptop');

    await laptop.send('hi', []);
    final reply = laptop.current!.messages.last;
    expect(reply.error, isNull);
    expect(reply.text, 'Hello from the host');
    expect(reply.usage!.outputTokens, 4);

    // Revoking on the host cuts the laptop off.
    await host.revoke(host.devices.single);
    await laptop.send('again', []);
    expect(laptop.current!.messages.last.error, contains('401'));

    await laptop.disconnectHost();
    expect(laptop.hasKey(ProviderKind.network), isFalse);
    expect(laptop.provider, isNot(ProviderKind.network));
  });
}

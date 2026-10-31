import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/tools/builtin_source.dart';
import 'package:ai_chatbot/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory dir;
  late Storage storage;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('builtin');
    storage = await Storage.openAt(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('DuckDuckGo results are parsed, ads skipped and links decoded', () async {
    final page = File('test/fixtures/ddg.html').readAsStringSync();
    final results = BuiltinToolSource.parseDuckDuckGo(page);
    expect(results.map((r) => r.url), ['https://flutter.dev/', 'https://dart.dev/overview']);
    expect(results.first.title, 'Flutter - Build apps for any screen');
    expect(results.first.snippet, 'Flutter transforms the app development process. Build, test, and deploy.');

    late http.Request sent;
    final source = BuiltinToolSource(storage, client: MockClient((req) async {
      sent = req;
      return http.Response(page, 200);
    }));
    final out = await source.call('web_search', {'query': 'flutter'});
    expect(sent.method, 'POST');
    expect(sent.bodyFields['q'], 'flutter');
    expect(out.text, startsWith('1. Flutter - Build apps for any screen\nhttps://flutter.dev/'));
  });

  test('web pages become readable text', () {
    final text = BuiltinToolSource.htmlToText('''
      <html><head><title>Hello page</title><style>p{color:red}</style></head>
      <body><nav>Menu</nav><h1>Main   heading</h1><p>First  paragraph.</p>
      <script>alert(1)</script><ul><li>One</li><li>Two</li></ul></body></html>''');
    expect(text, contains('Title: Hello page'));
    expect(text, contains('# Main heading'));
    expect(text, contains('First paragraph.'));
    expect(text, contains('- One\n- Two'));
    expect(text, isNot(contains('alert')));
    expect(text, isNot(contains('color:red')));
  });

  test('local and private addresses are blocked', () async {
    for (final host in ['localhost', '127.0.0.1', '192.168.1.1', '10.0.0.5', '172.20.1.1',
        '169.254.169.254', '::1', 'fd00::1', 'printer.local']) {
      await expectLater(BuiltinToolSource.ensurePublicHost(host), throwsA(isA<ToolError>()), reason: host);
    }
    await BuiltinToolSource.ensurePublicHost('8.8.8.8');
    final source = BuiltinToolSource(storage, client: MockClient((_) async => http.Response('x', 200)));
    final out = await source.call('read_web_page', {'url': 'http://192.168.1.1/admin'});
    expect(out.isError, isTrue);
    expect((await source.call('read_web_page', {'url': 'file:///etc/passwd'})).isError, isTrue);
  });

  test('redirects to private addresses are blocked too', () async {
    final source = BuiltinToolSource(storage, client: MockClient((req) async {
      return http.Response('', 302, headers: {'location': 'http://10.0.0.1/secret'});
    }));
    final out = await source.call('read_web_page', {'url': 'http://8.8.8.8/'});
    expect(out.isError, isTrue);
    expect(out.text, contains('blocked'));
  });

  test('calculator', () {
    expect(BuiltinToolSource.calculate('(17.5*3)^2/4').text, '(17.5*3)^2/4 = 689.0625');
    expect(BuiltinToolSource.calculate('2*pi').text, startsWith('2*pi = 6.28318'));
    expect(BuiltinToolSource.calculate('12 × 3').text, '12 × 3 = 36');
    expect(() => BuiltinToolSource.calculate('rm -rf /'), throwsA(isA<ToolError>()));
    expect(() => BuiltinToolSource.calculate('1/0'), throwsA(isA<ToolError>()));
  });

  test('date and time', () {
    final s = BuiltinToolSource.dateTime(DateTime(2026, 10, 31, 9, 5));
    expect(s, startsWith('Saturday, 2026-10-31 09:05:00'));
    expect(s, contains('UTC'));
  });

  test('notes: save, list, read, delete', () async {
    final source = BuiltinToolSource(storage);
    expect((await source.call('list_notes', {})).text, 'No notes yet.');
    await source.call('save_note', {'title': 'Shopping', 'text': 'milk, eggs'});
    expect((await source.call('list_notes', {})).text, 'Shopping');
    expect((await source.call('read_note', {'title': 'Shopping'})).text, 'milk, eggs');
    expect((await source.call('delete_note', {'title': 'Shopping'})).isError, isFalse);
    expect((await source.call('read_note', {'title': 'Shopping'})).isError, isTrue);
  });

  test('built-in tools are offered, can be switched off, and delete asks first', () async {
    final reg = ToolRegistry(storage);
    await reg.load();
    final names = reg.activeTools().map((t) => t.name).toList();
    expect(names, containsAll(['phone_web_search', 'phone_calculator', 'phone_save_note']));
    expect(reg.activeTools().firstWhere((t) => t.name == 'phone_delete_note').needsApproval, isTrue);
    expect(reg.activeTools().firstWhere((t) => t.name == 'phone_calculator').needsApproval, isFalse);

    await reg.setBuiltinEnabled('web_search', false);
    expect(reg.activeTools().map((t) => t.name), isNot(contains('phone_web_search')));
    final reloaded = ToolRegistry(storage);
    await reloaded.load();
    expect(reloaded.disabledBuiltins, {'web_search'});

    final r = await reg.execute(ToolCall(id: '1', name: 'phone_calculator', arguments: {'expression': '6*7'}));
    expect(r.text, '6*7 = 42');
    expect(reg.sourceNameFor('phone_calculator'), 'Built-in');
  });
}

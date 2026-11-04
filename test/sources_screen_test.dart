import 'dart:io';
import 'package:ai_chatbot/app.dart';
import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('named source UI saves metadata and keeps its key out of settings', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('sources_ui');
      final storage = await Storage.openAt(dir.path);
      state = AppState(storage, localModels: LocalModelStore(storage,
        dir: Directory('${dir.path}/models')..createSync()));
      await state.load();
    });
    addTearDown(() async { state.dispose(); await Hive.close(); await dir.delete(recursive: true); });
    await tester.pumpWidget(ChatApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('desktop-menu')), matching: find.text('Models')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'AI sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Add source'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Source name'), 'Lab API');
    await tester.enterText(find.widgetWithText(TextFormField, 'API base URL'), 'http://localhost:9000/v1');
    await tester.enterText(find.widgetWithText(TextFormField, 'API key (blank = keep existing)'), 'only-a-test-key');
    await tester.enterText(find.widgetWithText(TextFormField, 'Model IDs, one per line'), 'auto\nmodel-two');
    final save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save source'));
    await tester.runAsync(() async { await (save.onPressed! as dynamic)(); });
    await tester.pumpAndSettle();
    expect(state.sources.all.single.name, 'Lab API');
    expect(state.sources.all.single.shared, isFalse, reason: 'Adding a source must not automatically share it');
    expect(state.sources.all.single.models, ['auto', 'model-two']);
    expect(state.storage.getSetting('lab.sources'), isNot(contains('only-a-test-key')));
    expect(find.text('Lab API'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

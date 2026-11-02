import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/core/theme.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/features/settings/settings_screen.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory dir;
  late AppState state;

  Future<void> show(WidgetTester tester, Widget screen) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    dir = Directory.systemTemp.createTempSync('fs');
    await tester.runAsync(() async {
      final storage = await Storage.openAt(dir.path);
      state = AppState(storage,
          localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()));
      await state.load();
    });
    await tester.pumpWidget(AppScope(
        state: state, child: MaterialApp(theme: buildTheme(Brightness.light), home: screen)));
    await tester.pumpAndSettle();
  }

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('settings list free and paid providers separately', (tester) async {
    await show(tester, const SettingsScreen());
    expect(find.text('FREE AI (NO CREDIT CARD)'), findsOneWidget);
    expect(find.text('PAID AI'), findsOneWidget);
    for (final k in [ProviderKind.cerebras, ProviderKind.cloudflare, ProviderKind.freellmapi, ProviderKind.anthropic]) {
      expect(find.text(k.label), findsWidgets, reason: k.name);
    }
    expect(find.text('FREE AUTO'), findsNothing, reason: 'shown once a free key exists');
  });

  testWidgets('Cloudflare asks for the Account ID', (tester) async {
    await show(tester, const ProviderScreen(kind: ProviderKind.cloudflare));
    expect(find.widgetWithText(TextField, 'Account ID'), findsOneWidget);
    expect(find.textContaining('Free:'), findsOneWidget);
  });
}

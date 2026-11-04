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
  for (final width in [1400.0, 400.0]) {
    testWidgets('navigation at ${width.toInt()}px', (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Directory dir;
      late AppState state;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('home_shell');
        final storage = await Storage.openAt(dir.path);
        state = AppState(
          storage,
          localModels: LocalModelStore(
            storage,
            dir: Directory('${dir.path}/models')..createSync(),
          ),
        );
        await state.load();
      });
      addTearDown(() async {
        state.dispose();
        await Hive.close();
        await dir.delete(recursive: true);
      });
      await tester.pumpWidget(ChatApp(state: state));
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('desktop-menu'));
      if (width == 1400) {
        expect(menu, findsOneWidget);
        expect(find.byType(Drawer), findsNothing);
        for (final label in [
          'Chat',
          'Models',
          'Clients',
          'Tools',
          'Logs',
          'Settings',
        ]) {
          expect(
            find.descendant(of: menu, matching: find.text(label)),
            findsOneWidget,
          );
        }
        await tester.tap(
          find.descendant(of: menu, matching: find.text('Clients')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Stop all'), findsOneWidget);
        await tester.tap(
          find.descendant(of: menu, matching: find.text('Tools')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Coming soon'), findsNothing);
        await tester.tap(
          find.descendant(of: menu, matching: find.text('Settings')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Theme style'), findsOneWidget);
      } else {
        expect(menu, findsNothing);
        await tester.tap(find.byTooltip('Chats'));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);
        expect(find.text('New chat'), findsOneWidget);
        expect(find.descendant(of: find.byType(Drawer), matching: find.text('Settings')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

}

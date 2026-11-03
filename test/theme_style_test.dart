import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/core/theme.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('theme style persists and Cream remains selectable', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    late Directory dir;
    late Storage storage;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('theme_style');
      storage = await Storage.openAt(dir.path);
      state = AppState(
        storage,
        localModels: LocalModelStore(
          storage,
          dir: Directory('${dir.path}/models')..createSync(),
        ),
      );
      await state.setThemeStyle(AppThemeStyle.minimal);
      expect(storage.getSetting('themeStyle'), 'minimal');
      await state.load();
      expect(state.themeStyle, AppThemeStyle.minimal);
    });
    addTearDown(() async {
      state.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, style: state.themeStyle),
        home: const SizedBox(key: ValueKey('theme-preview')),
      ),
    );
    await tester.pumpAndSettle();
    final minimalContext = tester.element(
      find.byKey(const ValueKey('theme-preview')),
    );
    expect(Palette.of(minimalContext).background, Colors.white);
    expect(Theme.of(minimalContext).colorScheme.primary, Colors.black);
    expect(
      Theme.of(minimalContext).textTheme.bodyMedium!.fontFamily,
      contains('Inter'),
    );
    await tester.runAsync(() async {
      await state.setThemeStyle(AppThemeStyle.cream);
      expect(storage.getSetting('themeStyle'), 'cream');
      await state.load();
      expect(state.themeStyle, AppThemeStyle.cream);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, style: state.themeStyle),
        home: const SizedBox(key: ValueKey('theme-preview')),
      ),
    );
    await tester.pumpAndSettle();
    final creamContext = tester.element(
      find.byKey(const ValueKey('theme-preview')),
    );
    expect(Palette.of(creamContext).background, Palette.light.background);
    expect(Theme.of(creamContext).colorScheme.primary, Palette.accent);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

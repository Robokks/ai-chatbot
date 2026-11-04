import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/features/lab/labview_screen.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'LabVIEW page reports unknown connection and cannot open an unconfigured terminal',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Directory dir;
      late AppState state;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('labview-screen');
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
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: const MaterialApp(home: LabviewScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Last MCP check: Not configured'), findsOneWidget);
      expect(
        find.textContaining('does not verify that LabVIEW'),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(
          FilledButton,
          'Open configured DynasBrain terminal',
        ),
      );
      expect(button.onPressed, isNull);
      expect(find.text('Choose the DynasBrain project folder'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

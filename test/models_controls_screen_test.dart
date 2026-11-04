import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/llm/named_sources.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/features/lab/models_screen.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'models filters exclude unknown capabilities and metadata edits persist',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Directory dir;
      late AppState state;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('model_controls_ui');
        final storage = await Storage.openAt(dir.path);
        state = AppState(
          storage,
          localModels: LocalModelStore(
            storage,
            dir: Directory('${dir.path}/models')..createSync(),
          ),
        );
        await state.load();
        await state.sources.save(
          NamedSource(
            id: 's',
            name: 'Configured',
            url: 'https://x.test/v1',
            models: ['known-model', 'unknown-model'],
            modelOptions: {
              'known-model': ModelOptions(
                vision: true,
                tools: true,
                contextTokens: 128000,
              ),
            },
            quota: QuotaPolicy(tokens: 20000),
          ),
        );
      });
      addTearDown(() async {
        state.dispose();
        await Hive.close();
        await dir.delete(recursive: true);
      });
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: const MaterialApp(home: ModelsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('known-model'), findsOneWidget);
      expect(find.text('unknown-model'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, 'Vision'));
      await tester.pumpAndSettle();
      expect(find.text('known-model'), findsOneWidget);
      expect(find.text('unknown-model'), findsNothing);
      await tester.tap(find.text('known-model'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Context tokens (blank = unknown)'),
        '256000',
      );
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save model'),
      );
      await tester.runAsync(() async {
        await (save.onPressed! as dynamic)();
      });
      await tester.pumpAndSettle();
      expect(
        state.sources.all.single.modelOptions['known-model']!.contextTokens,
        256000,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Configure limits'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Requests per window (blank = unlimited)',
        ),
        '5',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Reset window in minutes'),
        '60',
      );
      final limits = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save limits'),
      );
      await tester.runAsync(() async {
        await (limits.onPressed! as dynamic)();
      });
      await tester.pumpAndSettle();
      expect(state.sources.all.single.quota.requests, 5);
      expect(state.sources.all.single.quota.windowSeconds, 3600);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

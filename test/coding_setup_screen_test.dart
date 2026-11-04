import 'package:ai_chatbot/features/lab/coding_setup_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('LabVIEW terminal uses the approved model callback', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: CodingSetupScreen(
          models: const ['approved'],
          startClaude: (_) async {},
          startCodex: (_) async {},
          startLabview: (model) async {
            selected = model;
          },
        ),
      ),
    );
    await tester.tap(find.text('Open LabVIEW terminal'));
    await tester.pumpAndSettle();
    expect(selected, 'approved');
  });
  testWidgets(
    'coding setup passes only selected approved model to launch callback',
    (tester) async {
      String? launched;
      await tester.pumpWidget(
        MaterialApp(
          home: CodingSetupScreen(
            models: const ['openai/approved'],
            startClaude: (model) async {
              launched = model;
            },
            startCodex: (_) async {},
          ),
        ),
      );
      await tester.tap(find.text('Open Claude Code'));
      await tester.pumpAndSettle();
      expect(launched, 'openai/approved');
      expect(find.text('Ready.'), findsOneWidget);
    },
  );
  testWidgets('coding setup disables launches without approved models', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CodingSetupScreen(
          models: const [],
          startClaude: (_) async {},
          startCodex: (_) async {},
        ),
      ),
    );
    final buttons = tester.widgetList<FilledButton>(find.byType(FilledButton));
    expect(buttons.every((button) => button.onPressed == null), isTrue);
    expect(
      find.text('Connect to Main and request model access first.'),
      findsOneWidget,
    );
  });
}

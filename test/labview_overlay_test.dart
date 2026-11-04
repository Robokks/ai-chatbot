import 'package:ai_chatbot/features/lab/labview_approval_overlay.dart';
import 'package:ai_chatbot/server/labview_approval_hub.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'Main sees remote LabVIEW request and explicitly allows one action',
    (tester) async {
      final hub = LabviewApprovalHub();
      var ran = false;
      await tester.pumpWidget(
        MaterialApp(
          home: LabviewApprovalOverlay(
            hub: hub,
            child: const Scaffold(body: Text('Chat')),
          ),
        ),
      );
      final result = hub.run(
        device: 'Instrument PC',
        tool: 'inspect_vi',
        arguments: {'vi': 'test.vi'},
        execute: () async {
          ran = true;
          return const ToolOutput('ok');
        },
      );
      await tester.pump();
      expect(find.text('Instrument PC requests LabVIEW'), findsOneWidget);
      expect(ran, isFalse);
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect((await result).text, 'ok');
      expect(ran, isTrue);
      expect(find.text('Instrument PC requests LabVIEW'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      hub.dispose();
    },
  );
}

import 'dart:io';

import 'package:ai_chatbot/app.dart';
import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/lab_role.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Windows asks for a role once and saves it', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('lab_role');
      final storage = await Storage.openAt(dir.path);
      state = AppState(storage, localModels: LocalModelStore(storage,
          dir: Directory('${dir.path}/models')..createSync()));
      await state.load();
    });
    addTearDown(() async {
      state.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(ChatApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('How will this PC be used?'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('role-main')),
    );
    await tester.runAsync(() async {
      await (button.onPressed! as dynamic)();
    });
    await tester.pumpAndSettle();
    expect(state.labRole, LabRole.main);
    expect(state.storage.getSetting('lab.role'), 'main');
    expect(find.byKey(const ValueKey('desktop-menu')), findsOneWidget);
    await tester.runAsync(state.load);
    expect(state.labRole, LabRole.main);
    await tester.pumpAndSettle();
    expect(find.text('How will this PC be used?'), findsNothing);
    expect(state.host.server.running, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

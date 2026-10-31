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
  testWidgets('attach menu tiles are compact, not full height', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('attach');
    late AppState state;
    await tester.runAsync(() async {
      final storage = await Storage.openAt(dir.path);
      state = AppState(storage,
          localModels: LocalModelStore(storage, dir: Directory('${dir.path}/m')..createSync()));
      await state.load();
    });
    await tester.pumpWidget(ChatApp(state: state));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add photos & files'));
    await tester.pumpAndSettle();

    final tile = find.ancestor(of: find.text('Files'), matching: find.byType(InkWell)).first;
    final height = tester.getSize(tile).height;
    expect(height, lessThan(140), reason: 'tile was $height px tall');
    // The sheet itself should only take a small part of the screen.
    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(find.text('Files')).dy, greaterThan(screen * 0.6));

    await tester.runAsync(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });
  });
}

import 'dart:io';

import 'package:ai_chatbot/core/device_stats.dart';
import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/core/theme.dart';
import 'package:ai_chatbot/data/local/image_gallery.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/features/images/images_screen.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:material_ui/material_ui.dart';

import 'image_maker_test.dart' show fakeEngine, tinyPng;

void main() {
  late Directory dir;
  late AppState state;

  Future<void> open(WidgetTester tester, {bool installed = false}) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    dir = Directory.systemTemp.createTempSync('imgscreen');
    await tester.runAsync(() async {
      final storage = await Storage.openAt(dir.path);
      final models = Directory('${dir.path}/m')..createSync();
      if (installed) File('${models.path}/${builtInImageModels.single.id}.gguf').writeAsBytesSync([1]);
      state = AppState(storage,
          localModels: LocalModelStore(storage, dir: models),
          imageEngine: fakeEngine([]),
          gallery: ImageGallery(storage, dir: Directory('${dir.path}/img')));
      await state.load();
    });
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ImagesScreen(
            deviceStats: DeviceStats(totalRamMb: 8192, freeRamMb: 4096, freeDiskBytes: 50 << 30)),
      ),
    ));
    await tester.runAsync(() => state.images.refresh());
    await tester.pumpAndSettle();
  }

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('without the model it offers the download', (tester) async {
    await open(tester);
    expect(find.text('SDXS 512'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Make image'), findsNothing);
  });

  testWidgets('asks for a description and shows pictures in the gallery', (tester) async {
    await open(tester, installed: true);
    expect(find.text('Make image'), findsOneWidget);
    // An empty description gets a clear message.
    await tester.tap(find.text('Make image'));
    await tester.pump();
    expect(find.text('Describe the picture first.'), findsOneWidget);

    // Making is covered by image_maker_test; here a finished picture shows up.
    await tester.runAsync(() => state.images.gallery.add(tinyPng, prompt: 'a red fox', madeOn: 'This device'));
    await tester.pump();
    expect(state.images.gallery.images.single.prompt, 'a red fox');
    expect(find.text('Your pictures'), findsOneWidget);
    expect(find.bySemanticsLabel('Picture: a red fox'), findsOneWidget);
  });
}

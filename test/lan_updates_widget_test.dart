import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/features/lab/updates_screen.dart';
import 'package:ai_chatbot/features/lab/app_updates_screen.dart';
import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/lab_role.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:ai_chatbot/server/lan_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('role wrapper asks an unpaired client to connect to Main', (
    tester,
  ) async {
    late Directory dir;
    late AppState app;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('update-wrapper');
      final storage = await Storage.openAt(dir.path);
      app = AppState(
        storage,
        localModels: LocalModelStore(
          storage,
          dir: Directory('${dir.path}/models')..createSync(),
        ),
      );
      await app.load();
      app.labRole = LabRole.client;
    });
    addTearDown(() async {
      app.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          home: AppUpdatesScreen(directoryLoader: () async => dir),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Connect this PC to Main before checking updates.'),
      findsOneWidget,
    );
    expect(find.text('Refresh Main update cache'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'client update screen checks Main only and leaves installation manual',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('update-widget');
      final requests = <Uri>[];
      final client = LanUpdateClient(
        baseUrl: 'http://192.168.1.2:8484',
        keyProvider: () async => 'test-pc-key',
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode(
              LanUpdateManifest(
                release: 'latest',
                publishedAt: DateTime.utc(2026),
                bytes: 12,
                sha256Hex: 'a' * 64,
              ).toJson(),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LanUpdatesScreen(client: client, destinationDirectory: dir),
        ),
      );
      expect(find.text('Check Main for update'), findsOneWidget);
      expect(find.text('Download verified ZIP'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('Check Main for update'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(requests.single.host, '192.168.1.2');
      expect(requests.single.path, '/updates/windows/manifest');
      expect(find.text('Download verified ZIP'), findsOneWidget);
      expect(find.textContaining('Installation stays manual.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      dir.deleteSync(recursive: true);
    },
  );
}

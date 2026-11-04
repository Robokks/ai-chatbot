import 'dart:io';
import 'package:ai_chatbot/app.dart';
import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/server/client_access.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Clients page approves a PC, saves rules, and persists Stop all', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Directory dir;
    late AppState state;
    late PairedDevice device;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('clients_ui');
      final storage = await Storage.openAt(dir.path);
      state = AppState(storage, localModels: LocalModelStore(storage,
        dir: Directory('${dir.path}/models')..createSync()));
      await state.load();
      await state.host.server.loadClients();
      device = await state.host.server.createKey('Lab PC');
      await state.host.server.updateAccess(device, ClientAccess(approved: false));
    });
    addTearDown(() async { state.dispose(); await Hive.close(); await dir.delete(recursive: true); });
    await tester.pumpWidget(ChatApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('desktop-menu')), matching: find.text('Clients')));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for approval'), findsOneWidget);
    final approve = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Approve 1 h'));
    await tester.runAsync(() async { await (approve.onPressed! as dynamic)(); });
    await tester.pumpAndSettle();
    expect(device.access.approved, isTrue);
    expect(device.access.expires!.difference(DateTime.now()).inMinutes, greaterThan(58));
    expect(device.access.requestsPerDay, 500);
    final stop = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Stop all'));
    await tester.runAsync(() async { await (stop.onChanged! as dynamic)(true); });
    await tester.pumpAndSettle();
    expect(state.host.server.stopAll, isTrue);
    expect(state.storage.getSetting('host.settings'), contains('"stopAll":true'));
    await tester.tap(find.text('Rules'));
    await tester.pumpAndSettle();
    final requests = find.widgetWithText(TextFormField, 'Requests per day (blank = unlimited)');
    await tester.enterText(requests, '-1');
    await tester.tap(find.text('Save rules'));
    await tester.pumpAndSettle();
    expect(find.text('Enter zero or a positive whole number'), findsOneWidget);
    await tester.enterText(requests, '10');
    final save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save rules'));
    await tester.runAsync(() async { await (save.onPressed! as dynamic)(); });
    await tester.pumpAndSettle();
    expect(device.access.requestsPerDay, 10);
    expect(device.access.services, contains('chat'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(state.host.server.running, isFalse, reason: 'Editing policy never starts sharing');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

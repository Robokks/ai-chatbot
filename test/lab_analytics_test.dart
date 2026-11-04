import 'dart:io';

import 'package:ai_chatbot/features/lab/analytics_screen.dart';
import 'package:material_ui/material_ui.dart';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/server/lab_analytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

void main() {
  test('exact windows, PC/model groups and unknown usage survive restart without content', () async {
    final directory = await Directory.systemTemp.createTemp('lab-analytics');
    final storage = await Storage.openAt(directory.path);
    final now = DateTime.utc(2026, 11, 4, 12);
    final analytics = LabAnalytics(storage, clock: () => now);
    await analytics.record(
      LabRequestEvent(
        deviceId: 'one',
        device: 'PC One',
        model: 'model-a',
        status: 'ok',
        time: now,
        inputTokens: 12,
        outputTokens: 5,
        durationMs: 100,
        firstTokenMs: 30,
      ),
    );
    await analytics.record(
      LabRequestEvent(
        deviceId: 'two',
        device: 'PC Two',
        model: 'model-b',
        status: 'error',
        time: now.subtract(const Duration(days: 2)),
      ),
    );
    await analytics.record(
      LabRequestEvent(
        deviceId: 'one',
        device: 'PC One',
        model: 'model-a',
        status: 'cancelled',
        time: now.subtract(const Duration(days: 8)),
      ),
    );
    await analytics.record(
      LabRequestEvent(
        deviceId: 'one',
        device: 'PC One',
        model: 'web',
        status: 'ok',
        kind: 'tool',
        time: now,
      ),
    );
    expect(analytics.summary(const Duration(days: 1)).requests, 1);
    final week = analytics.summary(const Duration(days: 7));
    expect(week.requests, 2);
    expect(week.successes, 1);
    expect(week.failures, 1);
    expect(week.inputTokens, 12);
    expect(week.inputSamples, 1);
    expect(week.latencyMs, 100);
    expect(week.by((e) => e.deviceId).keys, containsAll(['one', 'two']));
    final unknown = analytics.summary(
      const Duration(days: 30),
      deviceId: 'two',
    );
    expect(unknown.outputTokens, isNull);
    expect(unknown.firstTokenMs, isNull);
    expect(
      analytics.summary(const Duration(days: 30), model: 'model-a').cancelled,
      1,
    );
    await analytics.flush();
    final restored = LabAnalytics(storage, clock: () => now);
    expect(restored.summary(const Duration(days: 30)).requests, 3);
    expect(restored.recent.length, 4);
    final raw = storage.getSetting(LabAnalytics.storageKey)!;
    expect(raw, isNot(contains('prompt')));
    expect(raw, isNot(contains('response')));
    analytics.dispose();
    restored.dispose();
    await analytics.flush();
    await restored.flush();
    await Hive.close();
    await directory.delete(recursive: true);
  });
  testWidgets(
    'analytics shows actual measurements and selectable time windows',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('lab-analytics-ui'),
      ))!;
      final storage = (await tester.runAsync(
        () => Storage.openAt(directory.path),
      ))!;
      final now = DateTime.utc(2026, 11, 4);
      final analytics = LabAnalytics(storage, clock: () => now);
      await analytics.record(
        LabRequestEvent(
          deviceId: 'pc',
          device: 'Lab PC',
          model: 'Model One',
          status: 'ok',
          time: now,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: AnalyticsScreen(analytics: analytics)),
      );
      expect(find.text('24h'), findsOneWidget);
      expect(find.text('7d'), findsOneWidget);
      expect(find.text('30d'), findsOneWidget);
      expect(find.text('Requests over time'), findsOneWidget);
      expect(find.text('100.0%'), findsOneWidget);
      await tester.tap(find.text('7d'));
      await tester.pump();
      expect(
        find.text('Last 7 days · black: succeeded · red: failed or cancelled'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        analytics.dispose();
        await analytics.flush();
        await Hive.close();
        await directory.delete(recursive: true);
      });
    },
  );
  test('retention caps are explicit and old events expire', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lab-analytics-cap',
    );
    final storage = await Storage.openAt(directory.path);
    final now = DateTime.utc(2026, 11, 4);
    final analytics = LabAnalytics(storage, clock: () => now, maxEvents: 2);
    for (var i = 0; i < 4; i++) {
      await analytics.record(
        LabRequestEvent(
          deviceId: 'pc',
          device: 'PC',
          model: 'm',
          status: 'ok',
          time: now.subtract(Duration(hours: i)),
        ),
      );
    }
    expect(analytics.recent.length, 2);
    expect(analytics.truncatedBefore, isNotNull);
    await analytics.record(
      LabRequestEvent(
        deviceId: 'pc',
        device: 'PC',
        model: 'old',
        status: 'ok',
        time: now.subtract(const Duration(days: 31)),
      ),
    );
    expect(analytics.recent.any((e) => e.model == 'old'), isFalse);
    analytics.dispose();
    await analytics.flush();
    await Hive.close();
    await directory.delete(recursive: true);
  });
}

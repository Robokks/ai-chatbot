import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app alive on Android while it hosts models, with a persistent
/// notification. The server itself runs in the app; this service only stops
/// Android from suspending it.
class HostForegroundService {
  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<void> start(String address) async {
    if (!supported) return;
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'host_server',
        channelName: 'Sharing AI models',
        channelDescription: 'Shown while this device shares its AI models on your Wi-Fi.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    final text = 'Other devices can connect at $address';
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
          notificationTitle: 'Sharing AI models', notificationText: text);
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 8484,
        notificationTitle: 'Sharing AI models',
        notificationText: text,
        notificationInitialRoute: '/',
        callback: _startCallback,
      );
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
  }
}

@pragma('vm:entry-point')
void _startCallback() => FlutterForegroundTask.setTaskHandler(_IdleHandler());

class _IdleHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

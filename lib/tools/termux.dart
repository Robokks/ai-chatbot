import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'tool_source.dart';

/// Runs command-line programs on Android through the Termux app.
abstract class TermuxRunner {
  /// The runner used by the app; tests replace it.
  static TermuxRunner instance = ChannelTermuxRunner();

  /// Whether Termux was found and allowed us to run commands (last check).
  static bool ready = false;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  /// Re-checks Termux; call at startup and from the setup guide.
  static Future<bool> refresh() async {
    if (!isAndroid) return ready = false;
    try {
      ready = await instance.isInstalled() && await instance.hasPermission();
    } catch (_) {
      ready = false;
    }
    return ready;
  }

  Future<bool> isInstalled();
  Future<bool> hasPermission();
  Future<bool> requestPermission();
  Future<ToolOutput> run(String program, List<String> args, {String? cwd});
}

const termuxBin = '/data/data/com.termux/files/usr/bin';
const termuxHome = '/data/data/com.termux/files/home';

class ChannelTermuxRunner extends TermuxRunner {
  static const _channel = MethodChannel('chatbot/termux');

  @override
  Future<bool> isInstalled() async => await _channel.invokeMethod<bool>('isInstalled') ?? false;

  @override
  Future<bool> hasPermission() async => await _channel.invokeMethod<bool>('hasPermission') ?? false;

  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  @override
  Future<ToolOutput> run(String program, List<String> args, {String? cwd}) async {
    final path = program.startsWith('/') ? program : '$termuxBin/$program';
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('run', {
        'path': path,
        'args': args,
        'workdir': cwd ?? termuxHome,
      }).timeout(const Duration(minutes: 2));
      return termuxOutput(r ?? const {});
    } on TimeoutException {
      return const ToolOutput('Termux did not answer in time. Open Termux once and try again.', isError: true);
    } on PlatformException catch (e) {
      return ToolOutput(switch (e.code) {
        'not_installed' => 'Termux is not installed.',
        'no_permission' => 'Allow Chatbot to run commands in Termux (Settings → Tools → CLI).',
        _ => 'Termux error: ${e.message}',
      }, isError: true);
    }
  }
}

/// Formats Termux's result bundle like a normal process result.
ToolOutput termuxOutput(Map<String, dynamic> r) {
  final err = r['err'] as int? ?? 0;
  final errmsg = '${r['errmsg'] ?? ''}'.trim();
  // err != 0 means Termux itself refused (e.g. allow-external-apps not set).
  if (err != 0 && errmsg.isNotEmpty) {
    final hint = errmsg.contains('allow-external-apps')
        ? '\nIn Termux run: echo "allow-external-apps=true" >> ~/.termux/termux.properties && termux-reload-settings'
        : '';
    return ToolOutput('Termux could not run the command: $errmsg$hint', isError: true);
  }
  final exit = r['exitCode'] as int? ?? -1;
  final out = [
    'Exit code: $exit',
    if ('${r['stdout'] ?? ''}'.trim().isNotEmpty) 'Output:\n${r['stdout']}',
    if ('${r['stderr'] ?? ''}'.trim().isNotEmpty) 'Errors:\n${r['stderr']}',
  ].join('\n');
  return ToolOutput(clip(out), isError: exit != 0);
}

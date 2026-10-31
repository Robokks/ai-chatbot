import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'termux.dart';
import 'tool_source.dart';

/// Command-line tools run on a PC, or on Android through the Termux app.
bool get cliSupported => desktopCli || (TermuxRunner.isAndroid && TermuxRunner.ready);

/// Programs run directly on Windows, macOS and Linux.
bool get desktopCli => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// The program name a command starts with ("C:\\x\\git.exe status" → "git").
String programOf(String command) {
  var first = command.trim();
  if (first.startsWith('"')) {
    final end = first.indexOf('"', 1);
    first = end > 0 ? first.substring(1, end) : first.substring(1);
  } else {
    first = first.split(RegExp(r'\s+')).first;
  }
  var name = first.split(RegExp(r'[/\\]')).last.toLowerCase();
  for (final ext in ['.exe', '.cmd', '.bat', '.com']) {
    if (name.endsWith(ext)) name = name.substring(0, name.length - ext.length);
  }
  return name;
}

/// Quotes [value] as one shell argument.
String shellQuote(String value) => Platform.isWindows
    ? '"${value.replaceAll('"', r'\"')}"'
    : "'${value.replaceAll("'", r"'\''")}'";

Future<ToolOutput> runProcess(
  String executable,
  List<String> args, {
  String? workingDirectory,
  bool shell = false,
  Duration timeout = const Duration(minutes: 2),
}) async {
  try {
    final result = await Process.run(
      executable,
      args,
      workingDirectory: workingDirectory,
      runInShell: shell,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
    final out = [
      'Exit code: ${result.exitCode}',
      if ('${result.stdout}'.trim().isNotEmpty) 'Output:\n${result.stdout}',
      if ('${result.stderr}'.trim().isNotEmpty) 'Errors:\n${result.stderr}',
    ].join('\n');
    return ToolOutput(clip(out), isError: result.exitCode != 0);
  } on ProcessException catch (e) {
    return ToolOutput('Could not start "$executable": ${e.message}', isError: true);
  } catch (e) {
    return ToolOutput('Command failed: $e', isError: true);
  }
}

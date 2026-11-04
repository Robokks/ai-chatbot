import 'dart:io';
import 'cli_runner.dart';

/// Programs are explicitly added by this PC's user. AI text travels through stdin.
enum LocalProgram {
  powershell('PowerShell'), cmd('Command Prompt'), python('Python'), node('Node.js'), git('Git');
  const LocalProgram(this.label);
  final String label;
  String get executable => switch (this) {
    LocalProgram.powershell => 'powershell', LocalProgram.cmd => 'cmd',
    LocalProgram.python => Platform.isWindows ? 'python' : 'python3',
    LocalProgram.node => 'node', LocalProgram.git => 'git',
  };
}

({String executable, List<String> args, String input, String cwd}) localInvocation(
    LocalProgram program, Map<String, dynamic> arguments, {bool? windows}) {
  final win = windows ?? Platform.isWindows;
  final cwd = arguments['cwd'];
  if (cwd != null && cwd is! String) throw const FormatException('cwd must be a folder path');
  var code = arguments['code'];
  if (program == LocalProgram.git) {
    final args = arguments['args'];
    if (args is! List || args.any((a) => a is! String)) throw const FormatException('args must be a list of strings');
    code = win ? '& git ${args.map((a) => powershellQuote(a as String)).join(' ')}\nexit \$LASTEXITCODE'
        : 'exec git ${args.map((a) => shellQuote(a as String)).join(' ')}';
  } else if (code is! String || code.trim().isEmpty) {
    throw const FormatException('code must be a nonempty string');
  }
  final String executable;
  final List<String> args;
  switch (program) {
    case LocalProgram.powershell:
      if (!win) throw UnsupportedError('This tool requires Windows.');
      executable = 'powershell'; args = ['-NoProfile', '-NonInteractive', '-Command', '-'];
    case LocalProgram.cmd:
      if (!win) throw UnsupportedError('This tool requires Windows.');
      executable = 'cmd'; args = ['/D', '/Q'];
    case LocalProgram.python: executable = win ? 'python' : 'python3'; args = ['-'];
    case LocalProgram.node: executable = 'node'; args = ['-'];
    case LocalProgram.git:
      executable = win ? 'powershell' : 'sh';
      args = win ? ['-NoProfile', '-NonInteractive', '-Command', '-'] : ['-s'];
  }
  return (executable: executable, args: args, input: '$code\n\n', cwd: cwd as String? ?? Directory.current.path);
}

import 'cli_runner.dart';
import 'local_program.dart';
import '../server/coding_agents.dart';
import 'termux.dart';
import 'tool_source.dart';

/// One allowlisted command-line program the AI may run (PC only). Every run
/// needs the user's approval, which shows the exact command.
class CliToolSource extends ToolSource {
  CliToolSource(super.config, super.secret, {this.launcher = defaultLauncher});
  final AgentLauncher launcher;
  LocalProgram? get localProgram => LocalProgram.values.asNameMap()[config.variables['localProgram']];

  @override
  Future<List<SourceTool>> discover() async {
    if (!cliSupported) {
      throw UnsupportedError(TermuxRunner.isAndroid
          ? 'Set up Termux first (Settings → Tools → Add CLI program).'
          : 'Command-line tools only run on a PC or with Termux on Android.');
    }
    final local = localProgram;
    if (local != null) {
      return [SourceTool(name: 'run', description: 'Run ${local.label} on this PC. '
          'The user sees the code, arguments and folder and approves every run. '
          'Use only installed programs; nothing is installed automatically.',
        inputSchema: {'type': 'object', 'properties': {
          if (local == LocalProgram.git) 'args': {'type': 'array', 'items': {'type': 'string'}}
          else 'code': {'type': 'string', 'description': 'The complete script to run via stdin'},
          'cwd': {'type': 'string', 'description': 'Working folder on this PC'},
        }, 'required': [local == LocalProgram.git ? 'args' : 'code']}, alwaysAsk: true)];
    }
    return [
      SourceTool(
        name: 'run',
        description: 'Run the command-line program "${config.url}"'
            '${config.description.isEmpty ? '' : ': ${config.description}'}. '
            'Pass its arguments as a list. The user approves each run.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'args': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Command-line arguments, one per item',
            },
            'cwd': {'type': 'string', 'description': 'Optional working directory'},
          },
          'required': ['args'],
        },
        alwaysAsk: true,
      ),
    ];
  }

  @override
  Future<ToolOutput> call(String tool, Map<String, dynamic> arguments) {
    final local = localProgram;
    if (local != null) {
      if (config.url.trim() != local.executable) {
        return Future.value(const ToolOutput('Reset this local program in Tools before running it.', isError: true));
      }
      try {
        final invocation = localInvocation(local, arguments);
        return runAgent(executable: invocation.executable, args: invocation.args,
          workingDirectory: invocation.cwd, task: invocation.input, launcher: launcher,
          timeout: const Duration(minutes: 2), onProgress: (elapsed, line) => onProgress?.call(line));
      } catch (e) { return Future.value(ToolOutput('$e', isError: true)); }
    }
    final args = [for (final a in arguments['args'] as List? ?? const []) '$a'];
    final cwd = arguments['cwd'] as String?;
    if (!desktopCli) return TermuxRunner.instance.run(config.url.trim(), args, cwd: cwd);
    return runProcess(config.url.trim(), args, workingDirectory: cwd);
  }

  String describe(Map<String, dynamic> arguments) {
    final local = localProgram;
    if (local == null) return preview(config.url, arguments);
    try {
      final invocation = localInvocation(local, arguments);
      return 'Working folder: ${invocation.cwd}\n${local.label}:\n${invocation.input}';
    } catch (e) { return '$e'; }
  }

  /// The command line shown in the approval prompt.
  static String preview(String program, Map<String, dynamic> arguments) {
    final args = [for (final a in arguments['args'] as List? ?? const []) '$a'];
    return [program, ...args.map((a) => a.contains(' ') ? shellQuote(a) : a)].join(' ');
  }
}

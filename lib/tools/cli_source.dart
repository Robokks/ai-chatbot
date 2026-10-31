import 'cli_runner.dart';
import 'termux.dart';
import 'tool_source.dart';

/// One allowlisted command-line program the AI may run (PC only). Every run
/// needs the user's approval, which shows the exact command.
class CliToolSource extends ToolSource {
  CliToolSource(super.config, super.secret);

  @override
  Future<List<SourceTool>> discover() async {
    if (!cliSupported) {
      throw UnsupportedError(TermuxRunner.isAndroid
          ? 'Set up Termux first (Settings → Tools → Add CLI program).'
          : 'Command-line tools only run on a PC or with Termux on Android.');
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
    final args = [for (final a in arguments['args'] as List? ?? const []) '$a'];
    final cwd = arguments['cwd'] as String?;
    if (!desktopCli) return TermuxRunner.instance.run(config.url.trim(), args, cwd: cwd);
    return runProcess(config.url.trim(), args, workingDirectory: cwd);
  }

  /// The command line shown in the approval prompt.
  static String preview(String program, Map<String, dynamic> arguments) {
    final args = [for (final a in arguments['args'] as List? ?? const []) '$a'];
    return [program, ...args.map((a) => a.contains(' ') ? shellQuote(a) : a)].join(' ');
  }
}

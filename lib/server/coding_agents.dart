import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tools/tool_source.dart';

/// Coding agents the host can run for paired devices: the user's own
/// Claude Code and Codex installs on this PC.
enum CodingAgent {
  claudeCode('Claude Code', 'claude', 'claude_code', 'Anthropic Claude Code'),
  codex('Codex', 'codex', 'codex', 'OpenAI Codex');

  const CodingAgent(this.label, this.program, this.toolName, this.fullName);
  final String label;

  /// Command on PATH.
  final String program;

  /// MCP tool name.
  final String toolName;
  final String fullName;

  /// How to install it, shown when it isn't found.
  String get installHint => switch (this) {
        CodingAgent.claudeCode => 'Install: npm install -g @anthropic-ai/claude-code, then run "claude" once to sign in.',
        CodingAgent.codex => 'Install: npm install -g @openai/codex, then run "codex" once to sign in.',
      };

  /// Can continue the last conversation in the folder.
  bool get canContinue => this == CodingAgent.claudeCode;
}

/// A project folder the agents may work in.
class AgentFolder {
  AgentFolder({required this.path, required this.label, this.canEdit = false});

  final String path;
  String label;

  /// Agents may change files here (otherwise read only).
  bool canEdit;

  Map<String, dynamic> toJson() => {'path': path, 'label': label, 'canEdit': canEdit};

  factory AgentFolder.fromJson(Map<String, dynamic> j) => AgentFolder(
        path: j['path'] as String,
        label: j['label'] as String,
        canEdit: j['canEdit'] as bool? ?? false,
      );

  /// A short unique label from the folder name.
  static String labelFor(String path, Iterable<String> taken) {
    var base = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? 'project';
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    if (base.isEmpty) base = 'project';
    var label = base;
    for (var i = 2; taken.contains(label); i++) {
      label = '$base-$i';
    }
    return label;
  }
}

/// Saved coding-agent settings (setting `host.agents`).
class AgentSettings {
  AgentSettings({Set<CodingAgent>? enabled, List<AgentFolder>? folders})
      : enabled = enabled ?? {},
        folders = folders ?? [];

  final Set<CodingAgent> enabled;
  final List<AgentFolder> folders;

  AgentFolder? folder(String label) => folders.where((f) => f.label == label).firstOrNull;

  String toJson() => jsonEncode({
        'enabled': [for (final a in enabled) a.name],
        'folders': [for (final f in folders) f.toJson()],
      });

  factory AgentSettings.fromJson(String? raw) {
    if (raw == null) return AgentSettings();
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return AgentSettings(
      enabled: {
        for (final n in (j['enabled'] as List? ?? const [])) ?CodingAgent.values.asNameMap()[n],
      },
      folders: [
        for (final f in (j['folders'] as List? ?? const []))
          AgentFolder.fromJson(Map<String, dynamic>.from(f as Map)),
      ],
    );
  }
}

/// Command-line arguments for one run. They are fixed words only: the task
/// goes in through stdin and the folder is the working directory, so nothing
/// from another device can turn into shell code (Windows runs the npm `.cmd`
/// shims through cmd.exe).
List<String> agentArgs(CodingAgent agent, {required bool canEdit, bool continueLast = false}) =>
    switch (agent) {
      CodingAgent.claudeCode => [
          '-p',
          '--output-format',
          'text',
          '--permission-mode',
          canEdit ? 'acceptEdits' : 'plan',
          if (continueLast) '--continue',
        ],
      CodingAgent.codex => [
          'exec',
          '--skip-git-repo-check',
          '--sandbox',
          canEdit ? 'workspace-write' : 'read-only',
        ],
    };

/// Starts a program; replaced in tests.
typedef AgentLauncher = Future<Process> Function(
    String executable, List<String> args, String workingDirectory);

Future<Process> defaultLauncher(String executable, List<String> args, String workingDirectory) =>
    Process.start(executable, args,
        workingDirectory: workingDirectory, runInShell: Platform.isWindows);

/// Finds [agent] on this PC and returns its version, or null.
Future<String?> detectAgent(CodingAgent agent) async {
  try {
    final r = await Process.run(agent.program, ['--version'],
            runInShell: Platform.isWindows, stdoutEncoding: utf8, stderrEncoding: utf8)
        .timeout(const Duration(seconds: 20));
    if (r.exitCode != 0) return null;
    final v = '${r.stdout}'.trim().split('\n').first.trim();
    return v.isEmpty ? 'installed' : v;
  } catch (_) {
    return null;
  }
}

/// Runs one agent task: writes [task] to stdin, collects the output and
/// reports progress. Kills the program after [timeout].
Future<ToolOutput> runAgent({
  required String executable,
  required List<String> args,
  required String workingDirectory,
  required String task,
  AgentLauncher launcher = defaultLauncher,
  Duration timeout = const Duration(minutes: 20),
  Duration progressEvery = const Duration(seconds: 15),
  void Function(Duration elapsed, String lastLine)? onProgress,
  int maxChars = 100000,
}) async {
  if (!Directory(workingDirectory).existsSync()) {
    return ToolOutput('The folder "$workingDirectory" no longer exists on the host.', isError: true);
  }
  final Process process;
  try {
    process = await launcher(executable, args, workingDirectory);
  } on ProcessException catch (e) {
    return ToolOutput('Could not start "$executable" on the host: ${e.message}', isError: true);
  }
  final out = StringBuffer();
  final err = StringBuffer();
  var lastLine = '';
  void add(StringBuffer b, String s) {
    if (b.length < maxChars) b.write(s);
    final lines = s.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    if (lines.isNotEmpty) lastLine = lines.last;
  }

  final outDone = process.stdout.transform(utf8.decoder).forEach((s) => add(out, s));
  final errDone = process.stderr.transform(utf8.decoder).forEach((s) => add(err, s));
  try {
    process.stdin.write(task);
    await process.stdin.flush();
    await process.stdin.close();
  } catch (_) {
    // The program may exit before reading stdin; its output says why.
  }
  final clock = Stopwatch()..start();
  final ticker = Timer.periodic(progressEvery, (_) => onProgress?.call(clock.elapsed, lastLine));
  int code;
  var timedOut = false;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    process.kill();
    code = -1;
  } finally {
    ticker.cancel();
  }
  await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 5), onTimeout: () => []);
  if (timedOut) {
    return ToolOutput(
        clip('Stopped after ${timeout.inMinutes} minutes.\n${out.toString().trim()}'),
        isError: true);
  }
  final text = out.toString().trim();
  if (code != 0) {
    return ToolOutput(
        clip([
          'Exit code: $code',
          if (text.isNotEmpty) text,
          if (err.toString().trim().isNotEmpty) 'Errors:\n${err.toString().trim()}',
        ].join('\n')),
        isError: true);
  }
  return ToolOutput(clip(text.isEmpty ? '(no output)' : text, maxChars));
}

/// A run waiting for the host user's OK.
class HostApproval {
  HostApproval({
    required this.device,
    required this.agent,
    required this.folder,
    required this.task,
    required this.canEdit,
  });

  final DateTime time = DateTime.now();
  final String device;
  final CodingAgent agent;
  final String folder;
  final String task;
  final bool canEdit;
  final Completer<bool> _done = Completer();

  Future<bool> get result => _done.future;
  bool get decided => _done.isCompleted;

  void decide(bool allow) {
    if (!_done.isCompleted) _done.complete(allow);
  }
}

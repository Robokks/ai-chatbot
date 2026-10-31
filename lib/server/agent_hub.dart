import 'dart:async';

import 'package:flutter/foundation.dart';

import '../tools/tool_source.dart';
import 'coding_agents.dart';
import 'host_mcp.dart';

/// The host's coding agents: settings, detection, and the approval queue the
/// host user answers before each run.
class AgentHub extends ChangeNotifier implements AgentHost {
  AgentHub({
    required String? Function() load,
    required this.save,
    this.detect = detectAgent,
    this.launcher = defaultLauncher,
    this.approvalTimeout = const Duration(minutes: 2),
    this.runTimeout = const Duration(minutes: 20),
    this.progressEvery = const Duration(seconds: 15),
    this.log,
  }) : settings = AgentSettings.fromJson(load());

  final Future<void> Function(String) save;
  final Future<String?> Function(CodingAgent) detect;
  final AgentLauncher launcher;
  final Duration approvalTimeout;
  final Duration runTimeout;
  final Duration progressEvery;

  /// Adds a line to the host log: (device, what, status).
  final void Function(String device, String what, String status)? log;

  final AgentSettings settings;

  /// Version found for each agent; null means not installed.
  final Map<CodingAgent, String?> versions = {};
  bool detecting = false;

  /// Runs waiting for the user's OK, oldest first.
  final List<HostApproval> pending = [];

  /// "Allow for 30 min": runs are allowed without asking until then.
  DateTime? allowAllUntil;

  int running = 0;

  @override
  AgentSettings get agentSettings => settings;

  @override
  Set<CodingAgent> get availableAgents =>
      {for (final a in settings.enabled) if (versions[a] != null) a};

  bool get trusting => allowAllUntil != null && DateTime.now().isBefore(allowAllUntil!);

  /// Looks for the agents once; later calls do nothing. Not run at app
  /// start so normal launches never spawn `claude`/`codex`.
  Future<void> ensureDetected() =>
      detecting || versions.isNotEmpty ? Future.value() : refresh();

  Future<void> refresh() async {
    detecting = true;
    notifyListeners();
    for (final a in CodingAgent.values) {
      versions[a] = await detect(a);
    }
    detecting = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    await save(settings.toJson());
    notifyListeners();
  }

  Future<void> setEnabled(CodingAgent a, bool on) {
    on ? settings.enabled.add(a) : settings.enabled.remove(a);
    return _persist();
  }

  Future<void> addFolder(String path) {
    if (settings.folders.any((f) => f.path == path)) return Future.value();
    settings.folders.add(AgentFolder(
        path: path, label: AgentFolder.labelFor(path, settings.folders.map((f) => f.label))));
    return _persist();
  }

  Future<void> removeFolder(AgentFolder f) {
    settings.folders.remove(f);
    return _persist();
  }

  Future<void> setCanEdit(AgentFolder f, bool v) {
    f.canEdit = v;
    return _persist();
  }

  /// The host user's answer. [trustMinutes] also allows the next runs
  /// without asking for that long.
  void answer(HostApproval a, bool allow, {int? trustMinutes}) {
    if (allow && trustMinutes != null) {
      allowAllUntil = DateTime.now().add(Duration(minutes: trustMinutes));
    }
    a.decide(allow);
    pending.remove(a);
    notifyListeners();
  }

  void stopTrusting() {
    allowAllUntil = null;
    notifyListeners();
  }

  /// Denies everything waiting (the server stopped).
  void denyAll() {
    for (final a in List.of(pending)) {
      a.decide(false);
    }
    pending.clear();
    notifyListeners();
  }

  Future<bool> _approve(HostApproval a) async {
    if (trusting) return true;
    pending.add(a);
    notifyListeners();
    final allowed = await a.result.timeout(approvalTimeout, onTimeout: () => false);
    if (!a.decided) a.decide(false);
    if (pending.remove(a)) notifyListeners();
    return allowed;
  }

  @override
  Future<ToolOutput> runAgentTask(
    CodingAgent agent,
    AgentFolder folder,
    String task, {
    required String device,
    bool continueLast = false,
    void Function(Duration elapsed, String lastLine)? onProgress,
  }) async {
    final what = '${agent.label} · ${folder.label}';
    final approval = HostApproval(
        device: device, agent: agent, folder: folder.label, task: task, canEdit: folder.canEdit);
    if (!await _approve(approval)) {
      log?.call(device, what, 'denied');
      return const ToolOutput(
          'The user on the host did not allow this run (denied, or no answer within 2 minutes).',
          isError: true);
    }
    running++;
    notifyListeners();
    try {
      final out = await runAgent(
        executable: agent.program,
        args: agentArgs(agent, canEdit: folder.canEdit, continueLast: continueLast && agent.canContinue),
        workingDirectory: folder.path,
        task: task,
        launcher: launcher,
        timeout: runTimeout,
        progressEvery: progressEvery,
        onProgress: onProgress,
      );
      log?.call(device, what, out.isError ? 'error' : 'ok');
      return out;
    } finally {
      running--;
      notifyListeners();
    }
  }
}

import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/agent_hub.dart';
import 'package:ai_chatbot/server/coding_agents.dart';
import 'package:ai_chatbot/server/host_server.dart';
import 'package:ai_chatbot/tools/tool_registry.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

import 'tools_test.dart' show HostBackendFake;

/// Stands in for claude / codex: prints its arguments, then the task it
/// read from stdin.
Future<Process> echoAgent(String exe, List<String> args, String cwd) =>
    Process.start('sh', ['-c', r'echo "$0 $*"; cat', exe, ...args], workingDirectory: cwd);

Future<Process> slowAgent(String exe, List<String> args, String cwd) => Process.start(
    'sh', ['-c', 'cat > /dev/null; echo step one; sleep 1; echo finished'],
    workingDirectory: cwd);

void main() {
  test('commands are fixed words; the task is never an argument', () {
    expect(agentArgs(CodingAgent.claudeCode, canEdit: false),
        ['-p', '--output-format', 'text', '--permission-mode', 'plan']);
    expect(agentArgs(CodingAgent.claudeCode, canEdit: true, continueLast: true),
        ['-p', '--output-format', 'text', '--permission-mode', 'acceptEdits', '--continue']);
    expect(agentArgs(CodingAgent.codex, canEdit: false),
        ['exec', '--skip-git-repo-check', '--sandbox', 'read-only']);
    expect(agentArgs(CodingAgent.codex, canEdit: true),
        ['exec', '--skip-git-repo-check', '--sandbox', 'workspace-write']);
  });

  test('settings save and load; folder labels are unique and safe', () {
    final s = AgentSettings(
      enabled: {CodingAgent.codex},
      folders: [AgentFolder(path: '/home/me/my app', label: 'my-app', canEdit: true)],
    );
    final back = AgentSettings.fromJson(s.toJson());
    expect(back.enabled, {CodingAgent.codex});
    expect(back.folder('my-app')!.canEdit, isTrue);
    expect(AgentFolder.labelFor(r'C:\Users\me\my app\', ['x']), 'my-app');
    expect(AgentFolder.labelFor('/a/my-app', ['my-app']), 'my-app-2');
  });

  group('agents through the home server', () {
    late HostServer host;
    late AgentHub hub;
    late Directory dir;
    late Directory project;
    late ToolRegistry registry;
    late String key;
    final logged = <String>[];

    Future<void> start({
      AgentLauncher launcher = echoAgent,
      bool enable = true,
      Duration approvalTimeout = const Duration(seconds: 5),
    }) async {
      dir = await Directory.systemTemp.createTemp('agents');
      project = await Directory('${dir.path}/proj').create();
      String? saved;
      hub = AgentHub(
        load: () => saved,
        save: (v) async => saved = v,
        detect: (a) async => '1.0.0 (${a.label})',
        launcher: launcher,
        approvalTimeout: approvalTimeout,
        progressEvery: const Duration(milliseconds: 200),
        log: (d, w, s) => logged.add('$d $w $s'),
      );
      await hub.refresh();
      if (enable) {
        await hub.setEnabled(CodingAgent.claudeCode, true);
        await hub.addFolder(project.path);
      }
      host = HostServer(HostBackendFake(),
          loadDevices: () async => [], saveDevices: (_) async {}, agents: hub);
      await host.start(port: 0, address: InternetAddress.loopbackIPv4);
      key = (await host.createKey('Offline PC')).key;
      registry = ToolRegistry(await Storage.openAt('${dir.path}/db'));
      await registry.load();
      await registry.addOrUpdate(
        ToolSourceConfig(
            id: 'h', type: ToolSourceType.mcp, name: 'Internet PC', url: 'http://127.0.0.1:${host.mcpPort}/mcp'),
        secret: key,
      );
      expect(registry.status['h']!.error, isNull);
    }

    tearDown(() async {
      registry.dispose();
      await host.stop();
      await Hive.close();
      await dir.delete(recursive: true);
      logged.clear();
    });

    ToolSpec? agentTool(String name) => registry
        .activeTools()
        .where((t) => t.sourceId == 'h' && t.name.endsWith(name))
        .firstOrNull;

    Future<HostApproval> waitForApproval() async {
      for (var i = 0; i < 200 && hub.pending.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(hub.pending, isNotEmpty);
      return hub.pending.first;
    }

    test('not offered until switched on with a folder', () async {
      await start(enable: false);
      expect(agentTool('claude_code'), isNull);
      expect(agentTool('codex'), isNull);
    });

    test('offered as an ask-first tool; host Allow runs it with the task on stdin', () async {
      await start();
      final spec = agentTool('claude_code')!;
      expect(spec.needsApproval, isTrue);
      expect(agentTool('codex'), isNull);
      expect(agentTool('chat')!.needsApproval, isFalse);

      final run = registry.execute(ToolCall(
          id: '1', name: spec.name, arguments: {'task': 'Explain main.dart; rm -rf / & echo hi', 'folder': 'proj'}));
      final approval = await waitForApproval();
      expect(approval.device, 'Offline PC');
      expect(approval.agent, CodingAgent.claudeCode);
      expect(approval.canEdit, isFalse);
      hub.answer(approval, true);
      final r = await run;
      expect(r.isError, isFalse, reason: r.text);
      expect(r.text, contains('claude -p --output-format text --permission-mode plan'));
      expect(r.text, contains('Explain main.dart; rm -rf / & echo hi'));
      expect(logged.single, 'Offline PC Claude Code · proj ok');
    });

    test('Deny, or no answer, is reported to the AI', () async {
      await start(approvalTimeout: const Duration(milliseconds: 300));
      final spec = agentTool('claude_code')!;
      final run = registry.execute(ToolCall(id: '1', name: spec.name, arguments: {'task': 'x', 'folder': 'proj'}));
      hub.answer(await waitForApproval(), false);
      final r = await run;
      expect(r.isError, isTrue);
      expect(r.text, contains('did not allow'));

      final r2 = await registry.execute(ToolCall(id: '2', name: spec.name, arguments: {'task': 'y', 'folder': 'proj'}));
      expect(r2.isError, isTrue);
      expect(hub.pending, isEmpty);
    });

    test('Allow for 30 min skips the next approval', () async {
      await start();
      final spec = agentTool('claude_code')!;
      final first = registry.execute(ToolCall(id: '1', name: spec.name, arguments: {'task': 'a', 'folder': 'proj'}));
      hub.answer(await waitForApproval(), true, trustMinutes: 30);
      expect((await first).isError, isFalse);
      final second = await registry.execute(
          ToolCall(id: '2', name: spec.name, arguments: {'task': 'b', 'folder': 'proj', 'continue_last': true}));
      expect(second.isError, isFalse, reason: second.text);
      expect(second.text, contains('--continue'));
      hub.stopTrusting();
      expect(hub.trusting, isFalse);
    });

    test('folders outside the list are refused without asking', () async {
      await start();
      final spec = agentTool('claude_code')!;
      final r = await registry.execute(
          ToolCall(id: '1', name: spec.name, arguments: {'task': 'x', 'folder': '../etc'}));
      expect(r.isError, isTrue);
      expect(hub.pending, isEmpty);
    });

    test('progress from a long run reaches the chat', () async {
      await start(launcher: slowAgent);
      final spec = agentTool('claude_code')!;
      final progress = <String>[];
      final run = registry.execute(
        ToolCall(id: '1', name: spec.name, arguments: {'task': 'x', 'folder': 'proj'}),
        onProgress: progress.add,
      );
      hub.answer(await waitForApproval(), true);
      final r = await run;
      expect(r.isError, isFalse, reason: r.text);
      expect(r.text, contains('finished'));
      expect(progress, isNotEmpty);
      expect(progress.last, startsWith('Claude Code is working…'));
      expect(progress.any((p) => p.contains('step one')), isTrue);
    });

    test('a failing agent returns its exit code and errors', () async {
      await start(
          launcher: (e, a, c) => Process.start('sh', ['-c', 'cat >/dev/null; echo "not signed in" >&2; exit 3']));
      final spec = agentTool('claude_code')!;
      final run = registry.execute(ToolCall(id: '1', name: spec.name, arguments: {'task': 'x', 'folder': 'proj'}));
      hub.answer(await waitForApproval(), true);
      final r = await run;
      expect(r.isError, isTrue);
      expect(r.text, contains('Exit code: 3'));
      expect(r.text, contains('not signed in'));
    });
  });

  test('a missing folder or program gives a clear error', () async {
    final missing = await runAgent(
        executable: 'claude', args: const [], workingDirectory: '/no/such/dir', task: 'x');
    expect(missing.text, contains('no longer exists'));
    final noProgram = await runAgent(
        executable: 'definitely-not-installed-xyz',
        args: const [],
        workingDirectory: Directory.systemTemp.path,
        task: 'x',
        launcher: (e, a, c) => Process.start(e, a, workingDirectory: c));
    expect(noProgram.isError, isTrue);
    expect(noProgram.text, contains('Could not start'));
  });
}

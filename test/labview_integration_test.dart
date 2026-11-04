import 'dart:io';

import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/tools/labview_integration.dart';
import 'package:ai_chatbot/tools/tool_registry.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

class _DynasBrain extends ToolSource {
  _DynasBrain(super.config, super.secret);
  @override
  Future<List<SourceTool>> discover() async => [
    const SourceTool(
      name: 'inspect_vi',
      description: 'Inspect actual VI',
      inputSchema: {'type': 'object'},
    ),
  ];
  @override
  Future<ToolOutput> call(String tool, Map<String, dynamic> arguments) async =>
      const ToolOutput('VI inspected');
}

void main() {
  test('DynasBrain endpoint accepts lab interfaces and rejects remote or credential URLs', () {
    for (final url in [
      'http://localhost:9000/mcp',
      'http://127.0.0.1:1234/mcp',
      'http://192.168.1.50:8080/mcp',
      'https://10.0.0.2/mcp',
      'http://[::1]:8000/mcp',
    ]) {
      expect(LabviewIntegration.endpoint(url).path, '/mcp');
    }
    for (final url in [
      'file:///mcp',
      'http://8.8.8.8/mcp',
      'https://public.example/mcp',
      'http://user:key@localhost/mcp',
      'http://localhost/mcp?key=abc',
      'http://localhost/mcp#key',
      'http://localhost/other',
    ]) {
      expect(
        () => LabviewIntegration.endpoint(url),
        throwsFormatException,
        reason: url,
      );
    }
  });
  test('connection discovers real MCP tools, keeps keys separate and revokes disabled sharing', () async {
    final dir = await Directory.systemTemp.createTemp('labview');
    final storage = await Storage.openAt(dir.path);
    final registry = ToolRegistry(
      storage,
      sourceFactory: (c, k) => _DynasBrain(c, k),
    );
    final integration = LabviewIntegration(storage, registry);
    try {
      expect(integration.connectionStatus, 'Not configured');
      await integration.connect(
        'http://127.0.0.1:9000/mcp',
        key: 'test-secret',
      );
      final config = integration.config!;
      expect(
        integration.connectionStatus,
        'Connected · 1 MCP tools discovered',
      );
      expect(integration.diagnosticHint, contains('does not verify'));
      expect(config.askBeforeRun, isTrue);
      expect(registry.status[config.id]!.tools.single.name, 'inspect_vi');
      expect(
        storage.getSetting('tools.sources'),
        isNot(contains('test-secret')),
      );
      expect(await storage.readSecret('tool.${config.id}'), 'test-secret');
      expect(integration.sharedTools(), isEmpty);
      await integration.setShared(true);
      expect(integration.sharedTools().single.name, contains('inspect_vi'));
      expect(
        registry
            .activeTools()
            .where((t) => t.sourceId == config.id)
            .single
            .needsApproval,
        isTrue,
      );
      await registry.setSourceEnabled(config, false);
      expect(integration.sharedTools(), isEmpty);
      expect(integration.connectionStatus, 'Disabled');
      config.enabled = true;
      registry.status.remove(config.id);
      expect(integration.connectionStatus, 'Not checked in this app session');
      registry.status[config.id] = SourceStatus()
        ..error = 'Access denied: check the key';
      expect(integration.connectionStatus, contains('Connection failed'));
      expect(integration.diagnosticHint, contains('access key'));
      await integration.setShared(false);
      expect(integration.shared, isFalse);
    } finally {
      registry.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    }
  });
  test('expert preset preserves custom instructions, persists selection and restores safely', () async {
    final dir = await Directory.systemTemp.createTemp('labview-preset');
    final storage = await Storage.openAt(dir.path);
    final registry = ToolRegistry(storage);
    final integration = LabviewIntegration(storage, registry);
    var prompt = 'Use metric units and explain briefly.';
    Future<void> write(String value) async {
      prompt = value;
    }

    try {
      await integration.selectExpert(true, current: prompt, writePrompt: write);
      expect(prompt, startsWith('Use metric units and explain briefly.'));
      expect(prompt, contains(LabviewIntegration.expertPrompt));
      expect(
        LabviewIntegration(storage, registry).expertSelected(prompt),
        isTrue,
      );
      final saved = prompt;
      await integration.selectExpert(true, current: prompt, writePrompt: write);
      expect(
        prompt,
        saved,
        reason: 'Selecting the active preset must not duplicate it',
      );
      await integration.selectExpert(
        false,
        current: prompt,
        writePrompt: write,
      );
      expect(prompt, 'Use metric units and explain briefly.');
      await integration.selectExpert(true, current: prompt, writePrompt: write);
      prompt = 'My new custom prompt';
      await integration.selectExpert(
        false,
        current: prompt,
        writePrompt: write,
      );
      expect(
        prompt,
        'My new custom prompt',
        reason: 'Manual edits must survive turning the preset off',
      );
      expect(integration.expertSelected(prompt), isFalse);
    } finally {
      registry.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    }
  });
}

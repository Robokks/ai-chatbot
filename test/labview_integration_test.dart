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
      await integration.connect(
        'http://127.0.0.1:9000/mcp',
        key: 'test-secret',
      );
      final config = integration.config!;
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
      await integration.setShared(false);
      expect(integration.shared, isFalse);
    } finally {
      registry.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    }
  });
}

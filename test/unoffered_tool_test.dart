import 'dart:io';
import 'package:ai_chatbot/core/storage.dart';
import 'package:ai_chatbot/data/lab_role.dart';
import 'package:ai_chatbot/data/llm/llm_provider.dart';
import 'package:ai_chatbot/data/local/local_models.dart';
import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/state/app_state.dart';
import 'package:ai_chatbot/tools/tool_registry.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

class PrivateTool extends ToolSource {
  PrivateTool(super.config, super.secret);
  int calls = 0;
  @override Future<List<SourceTool>> discover() async => const [SourceTool(name: 'run', description: 'Private tool', inputSchema: {'type': 'object'})];
  @override Future<ToolOutput> call(String tool, Map<String, dynamic> arguments) async { calls++; return const ToolOutput('Must not run'); }
}
class ForgedToolProvider extends LlmProvider {
  ForgedToolProvider(ProviderSettings settings) : super(settings: settings, apiKey: 'test');
  @override Stream<ChatDelta> streamChat(ChatRequest request) async* {
    if (request.messages.last.role == Role.user) {
      expect(request.tools, isEmpty);
      yield ChatDelta(toolCalls: [ToolCall(id: 'forged', name: 'private_run', arguments: {})]);
    } else { yield const ChatDelta(text: 'Finished'); }
  }
  @override Future<List<String>> listModels() async => [];
}
void main() {
  test('a model cannot execute a known tool that Main did not allow in this chat', () async {
    final dir = await Directory.systemTemp.createTemp('unoffered');
    final storage = await Storage.openAt(dir.path);
    late PrivateTool tool;
    final registry = ToolRegistry(storage, sourceFactory: (c, key) => tool = PrivateTool(c, key));
    final state = AppState(storage, tools: registry, localModels: LocalModelStore(storage,
      dir: Directory('${dir.path}/models')..createSync()), providerFactory: (s, key) => ForgedToolProvider(s));
    try {
      await state.load();
      await registry.addOrUpdate(ToolSourceConfig(id: 'private', type: ToolSourceType.mcp, name: 'Private', url: 'fake'));
      await state.setKey(ProviderKind.network, 'test-main-key');
      await state.updateProviderSettings(ProviderSettings(kind: ProviderKind.network, models: ['local/one']));
      await state.setLabRole(LabRole.client);
      state.applyHostAccess({'access': {'tools': <String>[]}});
      await state.send('Try a tool', []);
      expect(tool.calls, 0);
      final result = state.current!.messages.firstWhere((m) => m.role == Role.tool).toolResults.single;
      expect(result.isError, isTrue);
      expect(result.text, contains('not offered or allowed'));
    } finally { registry.dispose(); state.dispose(); await Hive.close(); await dir.delete(recursive: true); }
  });
}

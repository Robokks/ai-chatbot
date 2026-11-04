import 'package:material_ui/material_ui.dart';
import '../../server/host_controller.dart';
import '../../state/app_state.dart';
import '../host/widgets.dart';
import '../settings/local_models_screen.dart';
import 'sources_screen.dart';

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key, this.onChat});
  final VoidCallback? onChat;
  @override Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final host = state.host;
    return ListenableBuilder(listenable: host, builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Models'), actions: [
        TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SourcesScreen())),
          child: const Text('AI sources')),
      ]),
      body: PageBody(children: [
        const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('Choose models for this PC and sources to share through Main. Per-PC rules are managed in Clients.')),
        const SectionTitle('Named sources'),
        if (state.sources.all.isEmpty) const Text('Add FreeLLMAPI or another named source using AI sources.'),
        for (final source in state.sources.all.where((s) => s.enabled)) ...[
          CardBox(children: [
            SwitchListTile(title: Text(source.name), subtitle: Text('${source.models.length} models'), value: source.shared,
              onChanged: (v) { source.shared = v; state.sources.save(source); }),
            for (final model in source.models)
              ListTile(title: Text(model), trailing: TextButton(onPressed: () async { await state.selectModel(source.kind, source.route(model)); if (context.mounted) onChat?.call(); }, child: const Text('Use in chat'))),
          ]), const SizedBox(height: 16),
        ],
        const SectionTitle('Existing provider sources'),
        for (final kind in HostController.shareableCloud)
          CardBox(children: [
            SwitchListTile(title: Text(kind.label), subtitle: Text('${state.providers[kind]?.models.length ?? 0} models'),
              value: host.sharedCloud.contains(kind), onChanged: (v) => host.setShareCloud(kind, v)),
            for (final model in state.providers[kind]?.models ?? <String>[])
              ListTile(dense: true, title: Text(model)),
          ]),
        const SectionTitle('Offline models'),
        ListTile(title: const Text('On-device GGUF models'), trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LocalModelsScreen()))),
      ]),
    ));
  }
}

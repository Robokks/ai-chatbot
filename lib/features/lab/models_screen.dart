import 'package:material_ui/material_ui.dart';

import '../../server/host_controller.dart';
import '../../data/llm/named_sources.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../host/widgets.dart';
import '../settings/local_models_screen.dart';
import 'sources_screen.dart';

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key, this.onChat});
  final VoidCallback? onChat;
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final host = state.host;
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Models'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SourcesScreen()),
              ),
              child: const Text('AI sources'),
            ),
          ],
        ),
        body: PageBody(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'Choose models for this PC and sources to share through Main. Per-PC rules are managed in Clients.',
              ),
            ),
            Row(
              children: [
                const Expanded(
                  child: SectionTitle('Routing and fallback chains'),
                ),
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _ChainEditor(catalog: state.sources),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add chain'),
                ),
              ],
            ),
            const Text(
              'Fallback happens only before an answer starts. Speed and reliability use observed requests; Smartest uses your priorities. Token totals are reported usage, not remaining provider quota.',
            ),
            for (final chain in state.sources.chains)
              CardBox(
                children: [
                  SwitchListTile(
                    title: Text('Auto · ${chain.name}'),
                    subtitle: Text(
                      '${chain.strategy.name} · ${chain.routes.length} models',
                    ),
                    value: chain.enabled,
                    onChanged: (v) {
                      chain.enabled = v;
                      state.sources.saveChain(chain);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Share through Main'),
                    value: chain.shared,
                    onChanged: (v) {
                      chain.shared = v;
                      state.sources.saveChain(chain);
                    },
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () async {
                          await state.selectModel(
                            state.sources.kindForChain(chain),
                            chain.route,
                          );
                          onChat?.call();
                        },
                        child: const Text('Use Auto in chat'),
                      ),
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => _ChainEditor(
                            catalog: state.sources,
                            existing: chain,
                          ),
                        ),
                        child: const Text('Edit chain'),
                      ),
                      TextButton(
                        onPressed: () => state.sources.removeChain(chain),
                        child: const Text('Remove chain'),
                      ),
                    ],
                  ),
                ],
              ),
            const SectionTitle('Named sources'),
            if (state.sources.all.isEmpty)
              const Text(
                'Add FreeLLMAPI or another named source using AI sources.',
              ),
            for (final source in state.sources.all.where((s) => s.enabled)) ...[
              CardBox(
                children: [
                  SwitchListTile(
                    title: Text(source.name),
                    subtitle: Text('${source.models.length} models'),
                    value: source.shared,
                    onChanged: (v) {
                      source.shared = v;
                      state.sources.save(source);
                    },
                  ),
                  for (final model in source.models)
                    ListTile(
                      title: Text(model),
                      subtitle: Text(
                        _health(state.sources.metrics[source.route(model)]),
                      ),
                      trailing: TextButton(
                        onPressed: () async {
                          await state.selectModel(
                            source.kind,
                            source.route(model),
                          );
                          if (context.mounted) onChat?.call();
                        },
                        child: const Text('Use in chat'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            const SectionTitle('Existing provider sources'),
            for (final kind in HostController.shareableCloud)
              CardBox(
                children: [
                  SwitchListTile(
                    title: Text(kind.label),
                    subtitle: Text(
                      '${state.providers[kind]?.models.length ?? 0} models',
                    ),
                    value: host.sharedCloud.contains(kind),
                    onChanged: (v) => host.setShareCloud(kind, v),
                  ),
                  for (final model
                      in state.providers[kind]?.models ?? <String>[])
                    ListTile(dense: true, title: Text(model)),
                ],
              ),
            const SectionTitle('Offline models'),
            ListTile(
              title: const Text('On-device GGUF models'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const LocalModelsScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _health(RouteHealth? stats) => stats == null
    ? 'No traffic measured yet'
    : '${stats.successes} successful · ${stats.failures} failed · ${stats.firstMs?.round() ?? 0} ms to first output · ${stats.inputTokens + stats.outputTokens} reported tokens';

class _ChainEditor extends StatefulWidget {
  const _ChainEditor({required this.catalog, this.existing});
  final NamedSources catalog;
  final RoutingChain? existing;
  @override
  State<_ChainEditor> createState() => _ChainEditorState();
}

class _ChainEditorState extends State<_ChainEditor> {
  late final _name = TextEditingController(
    text: widget.existing?.name ?? 'Default',
  );
  late final _selected = [...?widget.existing?.routes];
  late final _priorities = {...?widget.existing?.priorities};
  late var _strategy = widget.existing?.strategy ?? RoutingStrategy.manual;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Routing chain'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Chain name'),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<RoutingStrategy>(
              initialValue: _strategy,
              decoration: const InputDecoration(labelText: 'Strategy'),
              items: [
                for (final s in RoutingStrategy.values)
                  DropdownMenuItem(
                    value: s,
                    child: Text(switch (s) {
                      RoutingStrategy.manual => 'Manual (selection order)',
                      RoutingStrategy.fastest => 'Fastest',
                      RoutingStrategy.reliable => 'Most reliable',
                      RoutingStrategy.smartest => 'Smartest (your priorities)',
                    }),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _strategy = v);
              },
            ),
            const Text(
              'Select models in fallback order. Use one API format per chain to preserve conversation and tool history. Higher priority means smarter in your judgement.',
            ),
            for (final source in widget.catalog.all.where((s) => s.enabled))
              for (final model in source.models)
                CheckboxListTile(
                  title: Text('${source.name} · $model'),
                  subtitle: Text(
                    _selected.contains(source.route(model))
                        ? 'Position ${_selected.indexOf(source.route(model)) + 1}'
                        : source.kind.label,
                  ),
                  value: _selected.contains(source.route(model)),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(source.route(model));
                    } else {
                      _selected.remove(source.route(model));
                    }
                  }),
                ),
            if (_strategy == RoutingStrategy.smartest)
              for (final route in _selected)
                Row(
                  children: [
                    Expanded(child: Text(route)),
                    IconButton(
                      onPressed: () => setState(
                        () =>
                            _priorities[route] = (_priorities[route] ?? 0) - 1,
                      ),
                      icon: const Icon(Icons.remove),
                    ),
                    Text('${_priorities[route] ?? 0}'),
                    IconButton(
                      onPressed: () => setState(
                        () =>
                            _priorities[route] = (_priorities[route] ?? 0) + 1,
                      ),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
            if (_error != null) Text(_error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () async {
          try {
            await widget.catalog.saveChain(
              RoutingChain(
                id: widget.existing?.id ?? newId(),
                name: _name.text.trim(),
                routes: _selected,
                strategy: _strategy,
                priorities: _priorities,
                enabled: widget.existing?.enabled ?? true,
                shared: widget.existing?.shared ?? false,
              ),
            );
            if (context.mounted) Navigator.pop(context);
          } on FormatException catch (e) {
            setState(() => _error = e.message);
          }
        },
        child: const Text('Save chain'),
      ),
    ],
  );
}

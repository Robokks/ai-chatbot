import 'package:material_ui/material_ui.dart';

import '../../data/llm/named_sources.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../host/widgets.dart';

class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final catalog = state.sources;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI sources'),
        actions: [
          TextButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _SourceEditor(catalog: catalog),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Add source'),
          ),
        ],
      ),
      body: PageBody(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'Add FreeLLMAPI or a provider directly. Google AI Studio (Gemini), Groq and OpenRouter have native formats. NVIDIA NIM and Cloudflare Workers AI use OpenAI compatible with their API base URL. Quotas depend on your provider account; no free allowance is assumed.',
            ),
          ),
          if (catalog.all.isEmpty)
            const Text(
              'No named sources yet. Existing provider keys remain in Settings.',
            ),
          for (final source in catalog.all) ...[
            CardBox(
              children: [
                SwitchListTile(
                  value: source.enabled,
                  title: Text(source.name),
                  subtitle: Text(source.url),
                  onChanged: (value) {
                    source.enabled = value;
                    catalog.save(source);
                  },
                ),
                ListTile(
                  title: Text(
                    catalog.health[source.id] ?? 'Not checked this session',
                  ),
                  subtitle: Text(
                    '${source.models.length} models · ${catalog.keyCount(source)} keys stored',
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      try {
                        await catalog.check(source);
                      } catch (_) {}
                    },
                    child: const Text('Check'),
                  ),
                ),
                if (catalog.keyCount(source) > 0)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(catalog.keySummary(source)),
                  ),
                SwitchListTile(
                  title: const Text('Share through Main'),
                  value: source.shared,
                  onChanged: (value) {
                    source.shared = value;
                    catalog.save(source);
                  },
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            _SourceEditor(catalog: catalog, existing: source),
                      ),
                      child: const Text('Edit'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final remove = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('Remove ${source.name}?'),
                            content: const Text(
                              'Its saved API key will be removed from this PC.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Remove'),
                              ),
                            ],
                          ),
                        );
                        if (remove == true) await catalog.remove(source);
                      },
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

class _SourceEditor extends StatefulWidget {
  const _SourceEditor({required this.catalog, this.existing});
  final NamedSources catalog;
  final NamedSource? existing;
  @override
  State<_SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<_SourceEditor> {
  final _form = GlobalKey<FormState>();
  late final _id = widget.existing?.id ?? newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  final _key = TextEditingController();
  late final _models = TextEditingController(
    text: widget.existing?.models.join('\n') ?? '',
  );
  late ProviderKind _kind = widget.existing?.kind ?? ProviderKind.custom;
  late bool _requestUsage = widget.existing?.requestUsage ?? true;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _models.dispose();
    super.dispose();
  }

  Future<void> _save({bool check = false}) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = NamedSource(
        id: _id,
        name: _name.text.trim(),
        url: _url.text.trim(),
        kind: _kind,
        models: _models.text
            .split('\n')
            .map((m) => m.trim())
            .where((m) => m.isNotEmpty)
            .toSet()
            .toList(),
        requestUsage: _requestUsage,
        enabled: widget.existing?.enabled ?? true,
        shared: widget.existing?.shared ?? false,
      );
      await widget.catalog.save(
        source,
        keys: _key.text.trim().isEmpty ? null : _key.text.split('\n'),
      );
      _key.clear();
      if (check) {
        await widget.catalog.check(source);
        if (mounted) setState(() => _models.text = source.models.join('\n'));
      } else if (mounted) {
        Navigator.pop(context);
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not save or check this source. Verify the URL, key and network.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('AI source'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Source name'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Enter a name' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<ProviderKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'API format'),
                items: [
                  for (final kind in ProviderKind.values.where(
                    (k) => k != ProviderKind.local && k != ProviderKind.network,
                  ))
                    DropdownMenuItem(
                      value: kind,
                      child: Text(
                        kind == ProviderKind.custom
                            ? 'OpenAI compatible / FreeLLMAPI'
                            : kind.label,
                      ),
                    ),
                ],
                onChanged: widget.existing != null
                    ? null
                    : (v) {
                        if (v != null) {
                          setState(() {
                            _kind = v;
                            if (v != ProviderKind.custom) _url.text = v.baseUrl;
                          });
                        }
                      },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'API base URL',
                  hintText: 'http://localhost:PORT/v1',
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? 'Enter the API base URL'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _key,
                minLines: 1,
                maxLines: 4,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'API key (blank = keep existing)',
                  helperText: 'One key per line. Stored encrypted. Requests rotate keys; rate-limited keys pause for 60 seconds.',
                ),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Request token usage'),
                subtitle: const Text(
                  'Turn off if your compatible API rejects stream_options.',
                ),
                value: _requestUsage,
                onChanged: (v) => setState(() => _requestUsage = v),
              ),
              TextFormField(
                controller: _models,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Model IDs, one per line',
                  helperText: 'Check & load models can fill this list.',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      OutlinedButton(
        onPressed: _busy ? null : () => _save(check: true),
        child: const Text('Check & load models'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Save source'),
      ),
    ],
  );
}

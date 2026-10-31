import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../chat/model_picker.dart';
import 'local_models_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _Centered(
        children: [
          if (AppState.localSupported) ...[
            const _SectionTitle('Offline'),
            _Card(
              children: [
                ListTile(
                  leading: const ProviderAvatar(
                    kind: ProviderKind.local,
                    size: 32,
                  ),
                  title: const Text('On-device models'),
                  subtitle: Text(
                    state.localModels.installed.isEmpty
                        ? 'Run AI offline, no API key needed'
                        : '${state.localModels.installed.length} downloaded',
                    style: TextStyle(color: p.textMuted),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const LocalModelsScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const _SectionTitle('API keys'),
          _Card(
            children: [
              for (final k in ProviderKind.values)
                if (k != ProviderKind.local)
                  ListTile(
                    leading: ProviderAvatar(kind: k, size: 32),
                    title: Text(k.label),
                    subtitle: Text(
                      k == ProviderKind.custom
                          ? 'OpenAI-compatible server'
                          : state.hasKey(k)
                          ? 'Connected'
                          : 'Not set',
                      style: TextStyle(
                        color: state.hasKey(k) && k != ProviderKind.custom
                            ? const Color(0xFF2E9E5B)
                            : p.textMuted,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ProviderScreen(kind: k),
                      ),
                    ),
                  ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              'Keys are stored encrypted on this device and sent only to the provider you chat with.',
              style: TextStyle(color: p.textMuted, fontSize: 12.5),
            ),
          ),
          const _SectionTitle('Appearance'),
          _Card(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto_outlined),
                        label: Text('System'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined),
                        label: Text('Dark'),
                      ),
                    ],
                    selected: {state.themeMode},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => state.setThemeMode(s.first),
                  ),
                ),
              ),
            ],
          ),
          const _SectionTitle('Personalization'),
          _Card(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: _SystemPromptField(initial: state.systemPrompt),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SystemPromptField extends StatefulWidget {
  const _SystemPromptField({required this.initial});
  final String initial;

  @override
  State<_SystemPromptField> createState() => _SystemPromptFieldState();
}

class _SystemPromptFieldState extends State<_SystemPromptField> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      minLines: 3,
      maxLines: 8,
      onChanged: AppScope.read(context).setSystemPrompt,
      decoration: const InputDecoration(
        labelText: 'Custom instructions',
        hintText: 'e.g. Answer concisely. I am a software engineer.',
        alignLabelWithHint: true,
      ),
    );
  }
}

/// Key, endpoint and model list for one provider.
class ProviderScreen extends StatefulWidget {
  const ProviderScreen({super.key, required this.kind});

  final ProviderKind kind;

  @override
  State<ProviderScreen> createState() => _ProviderScreenState();
}

class _ProviderScreenState extends State<ProviderScreen> {
  late final AppState _state = AppScope.read(context);
  late final _key = TextEditingController(text: _state.keyFor(widget.kind));
  late final _url = TextEditingController(
    text: _state.providers[widget.kind]!.baseUrl,
  );
  final _newModel = TextEditingController();
  late List<String> _models = List.of(_state.providers[widget.kind]!.models);
  bool _obscure = true;
  bool _busy = false;
  String? _status;
  bool _ok = false;

  ProviderKind get k => widget.kind;

  @override
  void dispose() {
    _key.dispose();
    _url.dispose();
    _newModel.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _state.setKey(k, _key.text);
    await _state.updateProviderSettings(
      ProviderSettings(kind: k, baseUrl: _url.text.trim(), models: _models),
    );
    if (!_models.contains(_state.model) &&
        _state.provider == k &&
        _models.isNotEmpty) {
      await _state.selectModel(k, _models.first);
    }
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    await _save();
    try {
      final models = await _state.fetchModels(k, key: _key.text.trim());
      setState(() {
        _ok = true;
        _status = 'Key works. ${models.length} models available.';
      });
      if (mounted) _offerModels(models);
    } catch (e) {
      setState(() {
        _ok = false;
        _status = e.toString();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _offerModels(List<String> available) async {
    final chosen = Set.of(_models);
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (ctx, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Models to show',
                        style: serif(ctx, size: 20),
                      ),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, chosen),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scroll,
                  children: [
                    for (final m in {...available, ..._models})
                      CheckboxListTile(
                        value: chosen.contains(m),
                        title: Text(m),
                        onChanged: (v) => setSheet(
                          () => v! ? chosen.add(m) : chosen.remove(m),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null && result.isNotEmpty) {
      setState(
        () => _models = [
          ..._models.where(result.contains),
          ...result.where((m) => !_models.contains(m)),
        ],
      );
      await _save();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PopScope(
      onPopInvokedWithResult: (_, _) => _save(),
      child: Scaffold(
        appBar: AppBar(title: Text(k.label)),
        body: _Centered(
          children: [
            Row(
              children: [
                ProviderAvatar(kind: k, size: 44),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(k.label, style: serif(context, size: 24)),
                      Text(k.vendor, style: TextStyle(color: p.textMuted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _key,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: k == ProviderKind.custom
                    ? 'API key (optional)'
                    : 'API key',
                prefixIcon: const Icon(Icons.key_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show' : 'Hide',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            if (k.keyUrl.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(k.keyUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text('Get a ${k.label} key'),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            await _save();
                            messenger.showSnackBar(
                              const SnackBar(content: Text('Saved')),
                            );
                          },
                    child: const Text('Save'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _busy ? null : _test,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering_rounded, size: 18),
                    label: const Text('Test & load models'),
                  ),
                ),
              ],
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _ok
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: _ok
                          ? const Color(0xFF2E9E5B)
                          : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status!,
                        style: const TextStyle(fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
            const _SectionTitle('Models'),
            _Card(
              children: [
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorderItem: (a, b) =>
                      setState(() => _models.insert(b, _models.removeAt(a))),
                  children: [
                    for (final (i, m) in _models.indexed)
                      ListTile(
                        key: ValueKey(m),
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: Icon(
                            Icons.drag_indicator_rounded,
                            color: p.textMuted,
                          ),
                        ),
                        title: Text(prettyModel(m)),
                        subtitle: prettyModel(m) == m ? null : Text(m),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          onPressed: _models.length <= 1
                              ? null
                              : () => setState(() => _models.remove(m)),
                          icon: const Icon(Icons.close_rounded, size: 20),
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: TextField(
                    controller: _newModel,
                    decoration: InputDecoration(
                      hintText: 'Add model id',
                      suffixIcon: IconButton(
                        onPressed: _addModel,
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ),
                    onSubmitted: (_) => _addModel(),
                  ),
                ),
              ],
            ),
            const _SectionTitle('Advanced'),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Base URL',
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: IconButton(
                  tooltip: 'Reset',
                  onPressed: () => setState(() => _url.text = k.baseUrl),
                  icon: const Icon(Icons.restart_alt_rounded),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _capabilities(),
              style: TextStyle(color: p.textMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  void _addModel() {
    final m = _newModel.text.trim();
    if (m.isEmpty || _models.contains(m)) return;
    setState(() => _models.add(m));
    _newModel.clear();
  }

  String _capabilities() {
    final img = k.images ? 'Images: supported' : 'Images: not supported';
    final pdf = k.pdf
        ? 'PDFs: sent natively'
        : 'PDFs: text is extracted and sent';
    return '$img · $pdf · Text and code files: supported';
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: Palette.of(context).textMuted,
          fontSize: 12,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: children),
      ),
    );
  }
}

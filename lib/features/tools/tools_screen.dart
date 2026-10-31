import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../server/host_server.dart';
import '../../state/app_state.dart';
import '../../tools/cli_runner.dart';
import '../../tools/tool_registry.dart';
import '../../tools/tool_source.dart';
import '../host/widgets.dart';

IconData _iconFor(ToolSourceType t) => switch (t) {
      ToolSourceType.mcp => Icons.hub_outlined,
      ToolSourceType.utcp => Icons.menu_book_outlined,
      ToolSourceType.a2a => Icons.smart_toy_outlined,
      ToolSourceType.cli => Icons.terminal_rounded,
    };

String _builtinTitle(String name) => switch (name) {
      'web_search' => 'Web search',
      'read_web_page' => 'Read web pages',
      'calculator' => 'Calculator',
      'date_time' => 'Date & time',
      'device_info' => 'Device info',
      'save_note' => 'Save notes',
      'list_notes' => 'List notes',
      'read_note' => 'Read notes',
      'delete_note' => 'Delete notes',
      _ => name,
    };

IconData _builtinIcon(String name) => switch (name) {
      'web_search' => Icons.travel_explore_rounded,
      'read_web_page' => Icons.article_outlined,
      'calculator' => Icons.calculate_outlined,
      'date_time' => Icons.schedule_rounded,
      'device_info' => Icons.battery_std_rounded,
      _ => Icons.sticky_note_2_outlined,
    };

/// Settings → Tools: everything the AI may use while answering.
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final reg = state.tools;
    return ListenableBuilder(
      listenable: reg,
      builder: (context, _) {
        final p = Palette.of(context);
        final hostConnected = state.hasKey(ProviderKind.network);
        return Scaffold(
          appBar: AppBar(title: const Text('Tools')),
          body: PageBody(children: [
            const NoteBox(
              icon: Icons.build_outlined,
              text: 'Tools let the AI do things while it answers: search the web, calculate, '
                  'take notes, call apps or other AI agents, and run programs. Add MCP servers, '
                  'UTCP manuals, A2A agents and command-line programs. Every tool call shows '
                  'in the chat.',
            ),
            const SizedBox(height: 16),
            CardBox(children: [
              SwitchListTile(
                value: reg.enabled,
                onChanged: reg.setEnabled,
                title: const Text('Let the AI use tools', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${reg.activeTools().length} tools available'),
              ),
            ]),
            const SectionTitle('Built-in'),
            CardBox(children: [
              for (final t in reg.builtin.tools)
                SwitchListTile(
                  value: !reg.disabledBuiltins.contains(t.name),
                  onChanged: reg.enabled ? (v) => reg.setBuiltinEnabled(t.name, v) : null,
                  secondary: Icon(_builtinIcon(t.name)),
                  title: Text(_builtinTitle(t.name)),
                  subtitle: Text(t.alwaysAsk ? '${t.description} Asks first.' : t.description,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.textMuted)),
                ),
            ]),
            if (reg.configs.isNotEmpty) ...[
              const SectionTitle('Your tools'),
              CardBox(children: [
                for (final c in reg.configs) _SourceTile(config: c, status: reg.status[c.id]),
              ]),
            ],
            const SectionTitle('Add'),
            CardBox(children: [
              if (hostConnected && !reg.configs.any((c) => c.id == 'home-server-mcp'))
                ListTile(
                  leading: const Icon(Icons.router_outlined),
                  title: Text('Tools from ${state.connectedHostName ?? 'your home server'}'),
                  subtitle: const Text('Use the host\'s models as tools, via MCP'),
                  trailing: const Icon(Icons.add_rounded),
                  onTap: () => _addHostTools(context, state),
                ),
              for (final t in ToolSourceType.values)
                if (t != ToolSourceType.cli || cliSupported)
                  ListTile(
                    leading: Icon(_iconFor(t)),
                    title: Text('Add ${t.label}'),
                    subtitle: Text(switch (t) {
                      ToolSourceType.mcp => 'Model Context Protocol server (Streamable HTTP URL)',
                      ToolSourceType.utcp => 'Universal Tool Calling Protocol manual URL',
                      ToolSourceType.a2a => 'Another AI agent (Agent2Agent protocol)',
                      ToolSourceType.cli => 'A program on this PC, e.g. git or python. Asks before each run.',
                    }, style: TextStyle(color: p.textMuted)),
                    trailing: const Icon(Icons.add_rounded),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => SourceScreen(type: t),
                    )),
                  ),
            ]),
            if (!cliSupported)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                child: Text('Command-line tools are available in the Windows app.',
                    style: TextStyle(color: p.textMuted, fontSize: 12.5)),
              ),
          ]),
        );
      },
    );
  }

  Future<void> _addHostTools(BuildContext context, AppState state) async {
    final base = Uri.parse(state.providers[ProviderKind.network]!.baseUrl);
    final mcp = base.replace(port: (base.hasPort ? base.port : defaultHostPort) + 1, path: '/mcp');
    await state.tools.addOrUpdate(
      ToolSourceConfig(
        id: 'home-server-mcp',
        type: ToolSourceType.mcp,
        name: state.connectedHostName ?? 'Home server',
        url: mcp.toString(),
      ),
      secret: state.keyFor(ProviderKind.network),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.config, required this.status});

  final ToolSourceConfig config;
  final SourceStatus? status;

  @override
  Widget build(BuildContext context) {
    final reg = AppScope.read(context).tools;
    final p = Palette.of(context);
    final st = status;
    final subtitle = !config.enabled
        ? 'Off'
        : st == null || st.loading
            ? 'Connecting…'
            : st.error != null
                ? st.error!
                : '${st.tools.length} tool${st.tools.length == 1 ? '' : 's'} · ${config.type.label}';
    return ListTile(
      leading: Icon(_iconFor(config.type)),
      title: Text(config.name),
      subtitle: Text(subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: st?.error != null && config.enabled ? Theme.of(context).colorScheme.error : p.textMuted)),
      trailing: Switch(value: config.enabled, onChanged: (v) => reg.setSourceEnabled(config, v)),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SourceScreen(type: config.type, existing: config),
      )),
    );
  }
}

/// Add or edit one tool source.
class SourceScreen extends StatefulWidget {
  const SourceScreen({super.key, required this.type, this.existing});

  final ToolSourceType type;
  final ToolSourceConfig? existing;

  @override
  State<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends State<SourceScreen> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  late final _desc = TextEditingController(text: widget.existing?.description ?? '');
  late final _vars = TextEditingController(
      text: widget.existing?.variables.entries.map((e) => '${e.key}=${e.value}').join('\n') ?? '');
  final _secret = TextEditingController();
  late bool _ask = widget.existing?.askBeforeRun ?? widget.type == ToolSourceType.cli;
  bool _saving = false;

  ToolSourceType get type => widget.type;

  @override
  void dispose() {
    for (final c in [_name, _url, _desc, _vars, _secret]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final reg = AppScope.read(context).tools;
    final url = _url.text.trim();
    if (url.isEmpty) return;
    setState(() => _saving = true);
    final config = ToolSourceConfig(
      id: widget.existing?.id ?? newId(),
      type: type,
      name: _name.text.trim().isEmpty ? _defaultName(url) : _name.text.trim(),
      url: url,
      enabled: widget.existing?.enabled ?? true,
      askBeforeRun: _ask,
      description: _desc.text.trim(),
      variables: {
        for (final line in _vars.text.split('\n'))
          if (line.contains('='))
            line.substring(0, line.indexOf('=')).trim(): line.substring(line.indexOf('=') + 1).trim(),
      },
    );
    await reg.addOrUpdate(config, secret: _secret.text.isEmpty ? null : _secret.text.trim());
    if (!mounted) return;
    setState(() => _saving = false);
    final st = reg.status[config.id];
    if (st?.error == null) Navigator.of(context).pop();
  }

  String _defaultName(String url) {
    if (type == ToolSourceType.cli) return url.split(RegExp(r'[/\\]')).last;
    return Uri.tryParse(url)?.host.isNotEmpty == true ? Uri.parse(url).host : type.label;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final reg = state.tools;
    final p = Palette.of(context);
    final st = widget.existing == null ? null : reg.status[widget.existing!.id];
    final cli = type == ToolSourceType.cli;
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Add ${type.label}' : widget.existing!.name)),
      body: PageBody(children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 12),
        TextField(
          controller: _url,
          keyboardType: cli ? TextInputType.text : TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: switch (type) {
              ToolSourceType.mcp => 'Server URL',
              ToolSourceType.utcp => 'Manual URL',
              ToolSourceType.a2a => 'Agent URL or agent card URL',
              ToolSourceType.cli => 'Program',
            },
            hintText: switch (type) {
              ToolSourceType.mcp => 'https://example.com/mcp',
              ToolSourceType.utcp => 'https://api.example.com/utcp',
              ToolSourceType.a2a => 'https://agent.example.com',
              ToolSourceType.cli => r'git  or  C:\Python312\python.exe',
            },
          ),
        ),
        const SizedBox(height: 12),
        if (cli)
          TextField(
            controller: _desc,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'What it does (shown to the AI)',
              hintText: 'Git version control for the projects folder',
            ),
          )
        else
          TextField(
            controller: _secret,
            obscureText: true,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: widget.existing == null ? 'Access key (optional)' : 'New access key (leave empty to keep)',
              prefixIcon: const Icon(Icons.key_rounded),
            ),
          ),
        if (type == ToolSourceType.utcp) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _vars,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Variables (optional)',
              hintText: 'NAME=value, one per line. Unset \${VARS} use the access key.',
            ),
          ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: cli || _ask,
          onChanged: cli ? null : (v) => setState(() => _ask = v),
          title: const Text('Ask before each run'),
          subtitle: Text(cli
              ? 'Always on for programs: you see the exact command first.'
              : 'Otherwise the AI runs these tools on its own.'),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(
                  dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(widget.existing == null ? 'Add and connect' : 'Save and reconnect'),
        ),
        if (st?.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(st!.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (st != null && st.tools.isNotEmpty) ...[
          const SectionTitle('Tools'),
          CardBox(children: [
            for (final t in st.tools)
              ListTile(
                dense: true,
                title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(t.description, maxLines: 3, overflow: TextOverflow.ellipsis),
                trailing: t.alwaysAsk ? const Icon(Icons.shield_outlined, size: 18) : null,
              ),
          ]),
        ],
        if (st != null && st.skipped.isNotEmpty) ...[
          const SectionTitle('Not available'),
          for (final s in st.skipped)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $s', style: TextStyle(color: p.textMuted, fontSize: 13)),
            ),
        ],
        if (widget.existing != null) ...[
          const SizedBox(height: 24),
          Row(children: [
            OutlinedButton.icon(
              onPressed: () => reg.connect(widget.existing!),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reconnect'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () async {
                await reg.remove(widget.existing!);
                if (context.mounted) Navigator.of(context).pop();
              },
              child: Text('Remove', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ]),
        ],
      ]),
    );
  }
}

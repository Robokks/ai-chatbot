import 'package:material_ui/material_ui.dart';

import '../../server/client_access.dart';
import '../../server/host_server.dart';
import '../../state/app_state.dart';
import '../host/host_screen.dart';
import '../host/widgets.dart';

class ClientsScreen extends StatelessWidget {
  const ClientsScreen({super.key});

  Future<void> _approve(
    HostServer server,
    PairedDevice device,
    Duration? duration,
  ) => server.updateAccess(
    device,
    ClientAccess(
      models:
          device.access.models ??
          server.backend.sharedModels().map((m) => m.id).toSet(),
      tools: device.access.tools,
      services: device.access.services ?? {'chat', 'mcp', 'a2a'},
      expires: duration == null ? null : DateTime.now().add(duration),
      requestsPerDay: device.access.requestsPerDay ?? 500,
      tokensPerDay: device.access.tokensPerDay ?? 100000,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final host = AppScope.of(context).host;
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Clients'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const HostScreen()),
              ),
              child: const Text('Sharing settings'),
            ),
          ],
        ),
        body: FutureBuilder<void>(
          future: host.server.loadClients(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(child: Text('Could not load paired PCs.'));
            }
            if (!host.server.clientsLoaded) {
              return const Center(child: CircularProgressIndicator());
            }
            return PageBody(
              children: [
                CardBox(
                  children: [
                    SwitchListTile(
                      title: const Text('Stop all'),
                      subtitle: const Text(
                        'Immediately pause shared models and tools for every PC.',
                      ),
                      value: host.server.stopAll,
                      onChanged: host.setStopAll,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  host.server.running
                      ? 'Sharing is running'
                      : 'Sharing is off. Open Sharing settings to start it.',
                ),
                const SizedBox(height: 16),
                const NoteBox(
                  icon: Icons.shield_outlined,
                  text: 'New approvals allow the selected shared models and chat protocols, with 500 requests and 100,000 tokens per day. Use Rules to change limits or allow coding agents.',
                ),
                if (host.server.devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No paired PCs yet. Pair from a client using the PIN in Sharing settings.',
                    ),
                  ),
                for (final device in host.server.devices) ...[
                  const SizedBox(height: 16),
                  CardBox(
                    children: [
                      ListTile(
                        title: Text(device.name),
                        subtitle: Text(
                          device.access.blocked
                              ? 'Blocked'
                              : !device.access.approved
                              ? 'Waiting for approval'
                              : device.access.expires != null &&
                                    !DateTime.now().isBefore(
                                      device.access.expires!,
                                    )
                              ? 'Expired'
                              : device.lastSeen == null
                              ? 'Approved · not connected yet'
                              : 'Last seen ${device.lastSeen!.toLocal()}',
                        ),
                        trailing: TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => _RulesDialog(
                              server: host.server,
                              device: device,
                            ),
                          ),
                          child: const Text('Rules'),
                        ),
                      ),
                      if (device.via.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Via ${device.via.map((id) => host.server.devices.where((d) => d.id == id).firstOrNull?.name ?? 'Unavailable relay').join(' → ')}',
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          '${device.usage.day == ClientUsage.dayFor(DateTime.now()) ? device.usage.requests : 0} requests · '
                          '${device.usage.day == ClientUsage.dayFor(DateTime.now()) ? device.usage.tokens : 0} tokens today',
                        ),
                      ),
                      if (device.accessRequested)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('This PC requested access.'),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final entry in <String, Duration?>{
                              '1 h': const Duration(hours: 1),
                              '1 day': const Duration(days: 1),
                              '7 days': const Duration(days: 7),
                              'Always': null,
                            }.entries)
                              OutlinedButton(
                                onPressed: () =>
                                    _approve(host.server, device, entry.value),
                                child: Text('Approve ${entry.key}'),
                              ),
                            TextButton(
                              onPressed: () {
                                final access = ClientAccess.fromJson(
                                  device.access.toJson(),
                                )..blocked = !device.access.blocked;
                                host.server.updateAccess(device, access);
                              },
                              child: Text(
                                device.access.blocked ? 'Unblock' : 'Block',
                              ),
                            ),
                            TextButton(
                              onPressed: () => host.server.updateAccess(
                                device,
                                ClientAccess.fromJson(device.access.toJson())
                                  ..approved = false,
                              ),
                              child: const Text('Deny'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RulesDialog extends StatefulWidget {
  const _RulesDialog({required this.server, required this.device});
  final HostServer server;
  final PairedDevice device;
  @override
  State<_RulesDialog> createState() => _RulesDialogState();
}

class _RulesDialogState extends State<_RulesDialog> {
  final _form = GlobalKey<FormState>();
  late final _requests = TextEditingController(
    text: widget.device.access.requestsPerDay?.toString() ?? '',
  );
  late final _tokens = TextEditingController(
    text: widget.device.access.tokensPerDay?.toString() ?? '',
  );
  late final _models =
      widget.device.access.models?.toSet() ??
      widget.server.backend.sharedModels().map((m) => m.id).toSet();
  late final _services =
      widget.device.access.services?.toSet() ?? {'chat', 'mcp', 'a2a'};
  late bool _allTools = widget.device.access.tools == null;
  late final _tools = widget.device.access.tools?.toSet() ?? <String>{};
  Duration? _expiry = const Duration(days: 1);
  bool _saving = false;
  String? _error;
  static const _labels = {
    'chat': 'Chat / UTCP',
    'mcp': 'MCP connection',
    'a2a': 'A2A',
    'claude_code': 'Claude Code',
    'codex': 'Codex',
    'relay': 'Relay forwarding',
    'proxy': 'Package downloads (git / pip / npm)',
    'updates': 'LAN app updates',
    'labview': 'LabVIEW MCP tools',
    'web_search': 'Web search through Main',
    'read_web_page': 'Read web pages through Main',
  };
  String? _validate(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final n = int.tryParse(value.trim());
    return n == null || n < 0 ? 'Enter zero or a positive whole number' : null;
  }

  @override
  void dispose() {
    _requests.dispose();
    _tokens.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.server.updateAccess(
        widget.device,
        ClientAccess(
          approved: true,
          blocked: widget.device.access.blocked,
          expires: _expiry == null ? null : DateTime.now().add(_expiry!),
          models: _models,
          services: _services,
          tools: _allTools ? null : _tools,
          requestsPerDay: int.tryParse(_requests.text.trim()),
          tokensPerDay: int.tryParse(_tokens.text.trim()),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the rules. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Rules for ${widget.device.name}'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<Duration>(
                initialValue: _expiry,
                decoration: const InputDecoration(labelText: 'Access duration'),
                items: const [
                  DropdownMenuItem(
                    value: Duration(hours: 1),
                    child: Text('1 hour'),
                  ),
                  DropdownMenuItem(
                    value: Duration(days: 1),
                    child: Text('1 day'),
                  ),
                  DropdownMenuItem(
                    value: Duration(days: 7),
                    child: Text('7 days'),
                  ),
                  DropdownMenuItem<Duration>(
                    value: null,
                    child: Text('Always'),
                  ),
                ],
                onChanged: (v) => _expiry = v,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _requests,
                validator: _validate,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Requests per day (blank = unlimited)',
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _tokens,
                validator: _validate,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Tokens per day (blank = unlimited)',
                  helperText: 'A request needs space for its input and reply.',
                ),
              ),
              const SizedBox(height: 20),
              const Text('Allowed models'),
              if (widget.server.backend.sharedModels().isEmpty)
                const Text('Choose shared models in Sharing settings first.'),
              for (final model in widget.server.backend.sharedModels())
                CheckboxListTile(
                  title: Text(model.displayName ?? model.id),
                  value: _models.contains(model.id),
                  onChanged: (v) => setState(() {
                    v == true
                        ? _models.add(model.id)
                        : _models.remove(model.id);
                  }),
                ),
              const SizedBox(height: 16),
              const Text('Allowed services'),
              for (final entry in _labels.entries)
                CheckboxListTile(
                  title: Text(entry.value),
                  value: _services.contains(entry.key),
                  onChanged: (v) => setState(() {
                    v == true
                        ? _services.add(entry.key)
                        : _services.remove(entry.key);
                  }),
                ),
              const SizedBox(height: 16),
              const Text('Tools on the client PC'),
              CheckboxListTile(
                title: const Text('Allow all client tools'),
                value: _allTools,
                onChanged: (v) => setState(() => _allTools = v == true),
              ),
              if (!_allTools) ...[
                if (widget.device.clientTools.isEmpty)
                  const Text(
                    'The client has not reported its tools yet. No client tools will be allowed.',
                  ),
                for (final tool in widget.device.clientTools.entries)
                  CheckboxListTile(
                    title: Text(tool.key),
                    subtitle: Text(tool.value),
                    value: _tools.contains(tool.key),
                    onChanged: (v) => setState(() {
                      v == true
                          ? _tools.add(tool.key)
                          : _tools.remove(tool.key);
                    }),
                  ),
              ],
              if (_error != null) Text(_error!),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('Save rules'),
      ),
    ],
  );
}

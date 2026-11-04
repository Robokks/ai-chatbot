import 'package:material_ui/material_ui.dart';

import '../../state/app_state.dart';
import '../../data/lab_role.dart';
import '../../tools/labview_integration.dart';
import '../../server/labview_approval_hub.dart';
import '../../tools/tool_source.dart';
import '../host/widgets.dart';
import 'client_tools_screen.dart';

class LabviewScreen extends StatefulWidget {
  const LabviewScreen({super.key});
  @override
  State<LabviewScreen> createState() => _LabviewScreenState();
}

class _LabviewScreenState extends State<LabviewScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  String? _message;
  bool _busy = false;
  bool _loaded = false;
  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final integration = LabviewIntegration(state.storage, state.tools);
    if (!_loaded) {
      _url.text = integration.config?.url ?? '';
      _loaded = true;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('LabVIEW / DynasBrain')),
      body: PageBody(
        children: [
          const NoteBox(
            icon: Icons.science_outlined,
            text: 'On your LabVIEW PC, start your installed DynasBrain with dynasbrain serve. Copy its /mcp URL below. Connecting discovers its real tools; it does not run a VI.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'DynasBrain MCP URL',
              hintText: 'http://localhost:<port>/mcp',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Access key (optional; empty keeps existing key)',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() {
                      _busy = true;
                      _message = null;
                    });
                    try {
                      await integration.connect(
                        _url.text,
                        key: _key.text.isEmpty ? null : _key.text,
                      );
                      final status =
                          state.tools.status[LabviewIntegration.sourceId];
                      if (mounted) {
                        setState(
                          () => _message =
                              status?.error ??
                              '${status?.tools.length ?? 0} tools connected. Every local call asks first.',
                        );
                      }
                    } catch (e) {
                      if (mounted) setState(() => _message = '$e');
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: Text(_busy ? 'Connecting…' : 'Connect DynasBrain'),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_message!),
            ),
          SwitchListTile(
            value: integration.shared,
            title: const Text('Share through Main'),
            subtitle: const Text(
              'Main must grant the labview service to each PC. Every remote call asks Main first.',
            ),
            onChanged:
                state.labRole == LabRole.client ||
                    state.labRole == LabRole.relay
                ? null
                : (value) async {
                    await integration.setShared(value);
                    if (mounted) setState(() {});
                  },
          ),
          ListenableBuilder(
            listenable: LabviewApprovalHub.forStorage(state.storage),
            builder: (context, _) {
              final hub = LabviewApprovalHub.forStorage(state.storage);
              return Column(
                children: [
                  for (final request in hub.pending)
                    CardBox(
                      children: [
                        ListTile(
                          title: Text(
                            '${request.device} requests ${request.tool}',
                          ),
                          subtitle: Text(prettyJson(request.arguments)),
                        ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => hub.answer(request, false),
                              child: const Text('Deny'),
                            ),
                            FilledButton(
                              onPressed: () => hub.answer(request, true),
                              child: const Text('Allow once'),
                            ),
                          ],
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
          const SectionTitle('LabVIEW expert'),
          const Text(
            'Sets the chat system prompt to an inspection-first LabVIEW assistant. Your existing prompt is replaced.',
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              await state.setSystemPrompt(LabviewIntegration.expertPrompt);
              if (mounted) {
                setState(
                  () => _message =
                      'LabVIEW expert prompt is active for new requests.',
                );
              }
            },
            child: const Text('Use LabVIEW expert preset'),
          ),
          const SectionTitle('Offline Claude Code and Codex'),
          const Text(
            'Use the local coding-client setup with your paired Main connection. DynasBrain must launch Claude Code or Codex from that configured session so it inherits the local endpoint. Your Main key stays in the app’s encrypted key store.',
          ),
          TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ClientToolsScreen(controller: state.host.clientTools))),
            child: const Text('Set up local coding tools')),
          const SizedBox(height: 12),
          const Text(
            'To share a LabVIEW PC with other PCs, connect its private lab IP from Main, then enable LabVIEW sharing on Main. Main must approve each remote request before a tool runs.',
          ),
        ],
      ),
    );
  }
}

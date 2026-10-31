import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../server/host_controller.dart';
import '../../server/host_server.dart';
import '../../state/app_state.dart';
import '../chat/model_picker.dart';
import 'widgets.dart';

/// "Share this device": run the local server for the user's other devices.
class HostScreen extends StatelessWidget {
  const HostScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final host = state.host;
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final running = host.server.running;
        return Scaffold(
          appBar: AppBar(title: const Text('Share this device')),
          body: PageBody(children: [
            const NoteBox(
              icon: Icons.router_outlined,
              text: 'Turn an old phone or PC into a private AI server. Your other devices on '
                  'the same Wi-Fi can use its models, and so can apps that support the '
                  'OpenAI API.',
            ),
            const SizedBox(height: 16),
            CardBox(children: [
              SwitchListTile(
                value: running,
                onChanged: (v) => v ? host.start() : host.stop(),
                title: const Text('Share AI on this Wi-Fi',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(running
                    ? 'Running · ${host.server.devices.length} paired'
                        '${host.server.activeRequests > 0 ? ' · ${host.server.activeRequests} answering' : ''}'
                    : 'Off'),
              ),
            ]),
            if (host.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(host.error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (running) ...[
              const SectionTitle('Connect a device'),
              _ConnectCard(host: host),
            ],
            const SectionTitle('Shared models'),
            _SharedModels(host: host, state: state),
            if (running) ...[
              const SectionTitle('For other apps'),
              _OtherApps(host: host),
            ],
            const SectionTitle('Paired devices'),
            _Devices(host: host),
            if (host.server.log.isNotEmpty) ...[
              const SectionTitle('Recent requests'),
              _Log(entries: host.server.log),
            ],
            const SizedBox(height: 16),
            NoteBox(
              icon: Icons.shield_outlined,
              text: 'Only devices you pair, or apps you give a key, can use this server. '
                  'Shared cloud models are billed to this device\'s API keys. Traffic on '
                  'the Wi-Fi isn\'t encrypted, so share only on networks you trust.'
                  '${Theme.of(context).platform == TargetPlatform.android ? ' Keep this app '
                      'open in the background (don\'t swipe it away); a notification shows '
                      'while sharing.' : ''}',
            ),
          ]),
        );
      },
    );
  }
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.host});
  final HostController host;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final pin = host.server.pin;
    return CardBox(
      padding: const EdgeInsets.all(16),
      children: [
        Text('On your other device, open Chatbot → Settings → Connect to a home server. '
            'It should find "${host.deviceName}" automatically.',
            style: const TextStyle(fontSize: 14, height: 1.45)),
        const SizedBox(height: 16),
        Text('PIN', style: TextStyle(color: p.textMuted, fontSize: 12.5)),
        Row(
          children: [
            Expanded(
              child: Text(
                '${pin.substring(0, 3)} ${pin.substring(3)}',
                style: serif(context, size: 40, weight: FontWeight.w600)
                    .copyWith(letterSpacing: 4),
              ),
            ),
            IconButton(
              tooltip: 'New PIN',
              onPressed: host.server.newPin,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        Text('Changes every 10 minutes and after each pairing.',
            style: TextStyle(color: p.textMuted, fontSize: 12.5)),
        const SizedBox(height: 16),
        Text('Address', style: TextStyle(color: p.textMuted, fontSize: 12.5)),
        for (final a in host.addresses)
          _Copyable('$a:${host.server.port}'),
        if (host.addresses.isEmpty)
          const Text('No network address found. Is Wi-Fi on?'),
      ],
    );
  }
}

class _Copyable extends StatelessWidget {
  const _Copyable(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SelectableText(text,
              style: mono(size: 16, color: Palette.of(context).text)),
        ),
        IconButton(
          tooltip: 'Copy',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Copied'), width: 160));
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
      ],
    );
  }
}

class _SharedModels extends StatelessWidget {
  const _SharedModels({required this.host, required this.state});
  final HostController host;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final local = state.providers[ProviderKind.local]!.models;
    return CardBox(children: [
      SwitchListTile(
        value: host.shareLocal,
        onChanged: AppState.localSupported ? host.setShareLocal : null,
        secondary: const ProviderAvatar(kind: ProviderKind.local, size: 30),
        title: const Text('On-device models'),
        subtitle: Text(local.isEmpty
            ? 'None downloaded yet'
            : '${local.length} model${local.length == 1 ? '' : 's'} · free, runs on this device'),
      ),
      for (final k in HostController.shareableCloud)
        SwitchListTile(
          value: host.sharedCloud.contains(k),
          onChanged: state.hasKey(k) ? (v) => host.setShareCloud(k, v) : null,
          secondary: ProviderAvatar(kind: k, size: 30),
          title: Text(k.label),
          subtitle: Text(
            state.hasKey(k) ? 'Uses this device\'s API key (billed to you)' : 'No API key on this device',
            style: TextStyle(color: p.textMuted),
          ),
        ),
    ]);
  }
}

class _OtherApps extends StatelessWidget {
  const _OtherApps({required this.host});
  final HostController host;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final base = host.primaryAddress == null ? null : 'http://${host.primaryAddress}/v1';
    return CardBox(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Apps that support the OpenAI API (Open WebUI, Continue, scripts using the '
            'OpenAI SDK) can use this server with this base URL and an access key.',
            style: const TextStyle(fontSize: 14, height: 1.45)),
        if (base != null) ...[
          const SizedBox(height: 12),
          Text('Base URL', style: TextStyle(color: p.textMuted, fontSize: 12.5)),
          _Copyable(base),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _createKey(context),
            icon: const Icon(Icons.key_rounded, size: 18),
            label: const Text('Create access key'),
          ),
        ),
      ],
    );
  }

  Future<void> _createKey(BuildContext context) async {
    final name = TextEditingController(text: 'My app');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this key'),
        content: TextField(controller: name, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final d = await host.server.createKey(name.text.trim().isEmpty ? 'App' : name.text.trim());
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Access key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Copy it now: it is only shown once. Remove it under Paired devices '
                'to revoke access.'),
            const SizedBox(height: 12),
            _Copyable(d.key),
          ],
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );
  }
}

class _Devices extends StatelessWidget {
  const _Devices({required this.host});
  final HostController host;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final devices = host.server.devices;
    final when = DateFormat.MMMd().add_jm();
    return CardBox(children: [
      if (devices.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No devices yet.', style: TextStyle(color: p.textMuted)),
        ),
      for (final d in devices)
        ListTile(
          leading: const Icon(Icons.devices_other_rounded),
          title: Text(d.name),
          subtitle: Text(d.lastSeen == null ? 'Never used' : 'Last used ${when.format(d.lastSeen!)}'),
          trailing: TextButton(
            onPressed: () => _confirmRemove(context, d),
            child: const Text('Remove'),
          ),
        ),
    ]);
  }

  Future<void> _confirmRemove(BuildContext context, PairedDevice d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text('It will no longer be able to use this server until paired again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await host.server.revoke(d);
  }
}

class _Log extends StatelessWidget {
  const _Log({required this.entries});
  final List<HostLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final time = DateFormat.jm();
    return CardBox(children: [
      for (final e in entries.take(10))
        ListTile(
          dense: true,
          leading: Icon(
            e.status == 'ok' ? Icons.check_circle_outline : Icons.error_outline,
            size: 20,
            color: e.status == 'ok' ? const Color(0xFF2E9E5B) : p.textMuted,
          ),
          title: Text('${e.device} → ${prettyModel(e.model)}'),
          subtitle: Text('${time.format(e.time)}'
              '${e.outputTokens != null ? ' · ${e.outputTokens} tokens' : ''}'
              '${e.status != 'ok' ? ' · ${e.status}' : ''}'),
        ),
    ]);
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/device_stats.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../server/discovery.dart';
import '../../state/app_state.dart';
import '../chat/model_picker.dart';
import 'widgets.dart';

/// Find a host on the Wi-Fi (or type its address) and pair with its PIN.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _address = TextEditingController();
  StreamSubscription<List<FoundHost>>? _discovery;
  List<FoundHost> _found = [];
  bool _searching = !kIsWeb;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _discovery = discoverHosts().listen(
        (hosts) => setState(() => _found = hosts),
        onError: (_) => setState(() => _searching = false),
      );
    }
  }

  @override
  void dispose() {
    _discovery?.cancel();
    _address.dispose();
    super.dispose();
  }

  Future<String> _deviceName() async {
    final d = await readDeviceStats();
    return d.name ?? (kIsWeb ? 'Browser' : Platform.localHostname);
  }

  Future<void> _connect(Uri base, {String? knownName}) async {
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = knownName ?? await checkHost(base);
      if (!mounted) return;
      final pin = await _askPin(name);
      if (pin == null) return;
      await state.connectToHost(base, pin, name, await _deviceName());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Connected to $name')));
      Navigator.of(context).pop();
    } on PairingException catch (e) {
      setState(() => _error = e.message);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Connected, but could not load models: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPin(String hostName) {
    final pin = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pair with $hostName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter the 6-digit PIN shown on the host under Share this device.'),
            const SizedBox(height: 12),
            TextField(
              controller: pin,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(fontSize: 24, letterSpacing: 6),
              decoration: const InputDecoration(counterText: '', hintText: '000000'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, pin.text), child: const Text('Pair')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    final connected = state.hasKey(ProviderKind.network);
    final models = state.providers[ProviderKind.network]!.models;

    return Scaffold(
      appBar: AppBar(title: const Text('Connect to a home server')),
      body: PageBody(children: [
        const NoteBox(
          icon: Icons.wifi_rounded,
          text: 'Use the AI models of another device on the same Wi-Fi, for example an old '
              'phone running Chatbot with "Share this device" turned on.',
        ),
        if (connected) ...[
          const SectionTitle('Connected'),
          CardBox(children: [
            ListTile(
              leading: const ProviderAvatar(kind: ProviderKind.network, size: 32),
              title: Text(state.connectedHostName ?? 'Home server'),
              subtitle: Text('${models.length} shared model${models.length == 1 ? '' : 's'}'),
            ),
            for (final m in models.take(8))
              ListTile(dense: true, title: Text(prettyModel(m)), subtitle: Text(m)),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(children: [
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await state.refreshHostModels();
                          } catch (e) {
                            messenger.showSnackBar(SnackBar(content: Text('Host not reachable: $e')));
                          }
                        },
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Refresh models'),
                ),
                const Spacer(),
                TextButton(onPressed: state.disconnectHost, child: const Text('Disconnect')),
              ]),
            ),
          ]),
        ],
        const SectionTitle('Hosts on this Wi-Fi'),
        CardBox(children: [
          for (final h in _found)
            ListTile(
              leading: const Icon(Icons.router_rounded),
              title: Text(h.name),
              subtitle: Text('${h.address}:${h.port}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => _connect(h.base, knownName: h.name),
            ),
          if (_found.isEmpty)
            ListTile(
              leading: _searching
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search_off_rounded),
              title: Text(_searching ? 'Searching…' : 'Automatic search is not available here'),
              subtitle: const Text('Make sure sharing is on and both devices use the same Wi-Fi.'),
            ),
        ]),
        const SectionTitle('Or enter the address'),
        TextField(
          controller: _address,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: '192.168.1.5:8484',
            prefixIcon: Icon(Icons.link_rounded),
          ),
          onSubmitted: (_) => _connectTyped(),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _busy ? null : _connectTyped,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Connect'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 16),
        Text(
          'The host shows its address and PIN on its Share this device screen.',
          style: TextStyle(color: p.textMuted, fontSize: 12.5),
        ),
      ]),
    );
  }

  void _connectTyped() {
    try {
      _connect(parseHostAddress(_address.text));
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }
}

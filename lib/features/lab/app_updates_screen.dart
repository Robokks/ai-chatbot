import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/lab_role.dart';
import '../../data/models.dart';
import '../../server/lan_updates.dart';
import '../../state/app_state.dart';
import 'updates_screen.dart';

/// Role-aware entry point. Client and Relay always download from their paired
/// upstream; only Main can refresh the official release cache over the internet.
class AppUpdatesScreen extends StatefulWidget {
  const AppUpdatesScreen({super.key, this.directoryLoader});

  /// Injectable folder lookup keeps widget tests independent of native plugins.
  final Future<Directory> Function()? directoryLoader;
  @override
  State<AppUpdatesScreen> createState() => _AppUpdatesScreenState();
}

class _AppUpdatesScreenState extends State<AppUpdatesScreen> {
  LanUpdateClient? _client;
  LanUpdateCache? _cache;
  Directory? _destination;
  String? _error;
  String? _binding;
  int _generation = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final settings = app.providers[ProviderKind.network];
    final binding =
        '${app.labRole}|${settings?.baseUrl}|${app.keyFor(ProviderKind.network)}';
    if (binding == _binding) return;
    _binding = binding;
    final generation = ++_generation;
    _client?.close();
    _client = null;
    _cache = null;
    _destination = null;
    _error = null;
    _prepare(app, generation);
  }

  Future<Directory> _directory() async {
    if (widget.directoryLoader case final loader?) return loader();
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      return Directory('${downloads.path}/AI Chatbot updates');
    }
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/updates/downloads');
  }

  Future<void> _prepare(AppState app, int generation) async {
    try {
      final destination = await _directory();
      if (!mounted || generation != _generation) return;
      if (app.labRole == LabRole.main) {
        final cache = await app.host.updatesCache;
        if (!mounted || generation != _generation) return;
        setState(() {
          _cache = cache;
          _destination = destination;
        });
      } else if (app.labRole == LabRole.client ||
          app.labRole == LabRole.relay) {
        final settings = app.providers[ProviderKind.network];
        if (settings == null || !app.hasKey(ProviderKind.network)) {
          setState(
            () => _error = 'Connect this PC to Main before checking updates.',
          );
          return;
        }
        final client = LanUpdateClient(
          baseUrl: settings.baseUrl,
          keyProvider: () async => app.keyFor(ProviderKind.network),
        );
        setState(() {
          _client = client;
          _destination = destination;
        });
      } else {
        setState(
          () => _error = 'Choose Main, Client, or Relay in Settings first.',
        );
      }
    } on Object {
      if (mounted && generation == _generation) {
        setState(
          () => _error = 'Could not open the updates folder. Check this PC’s file permissions.',
        );
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_destination != null && (_cache != null || _client != null)) {
      return LanUpdatesScreen(
        cache: _cache,
        client: _client,
        destinationDirectory: _destination!,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Windows updates')),
      body: Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      ),
    );
  }
}

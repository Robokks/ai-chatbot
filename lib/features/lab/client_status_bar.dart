import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../data/models.dart';
import '../../server/client_connection.dart';
import '../../state/app_state.dart';
import '../host/connect_screen.dart';
import 'client_update_banner.dart';

class ClientStatusBar extends StatefulWidget {
  const ClientStatusBar({super.key});
  @override
  State<ClientStatusBar> createState() => _ClientStatusBarState();
}

class _ClientStatusBarState extends State<ClientStatusBar> {
  ClientConnection? _connection;
  Timer? _timer;
  String? _binding;
  Map<String, dynamic>? _snapshot;
  bool _busy = false;
  String? _error;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final settings = state.providers[ProviderKind.network];
    final binding =
        '${settings?.baseUrl}|${state.keyFor(ProviderKind.network)}';
    if (_binding == binding) return;
    _binding = binding;
    _connection?.close();
    _timer?.cancel();
    _connection = null;
    _snapshot = null;
    if (state.hasKey(ProviderKind.network) && settings != null) {
      _connection = ClientConnection(
        settings.baseUrl,
        state.keyFor(ProviderKind.network),
      );
      Future<void>(_refresh);
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    final connection = _connection;
    if (_busy || connection == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final snapshot = await connection.access();
      if (!mounted || connection != _connection) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
      final state = AppScope.read(context);
      state.applyHostAccess(snapshot);
      try {
        await connection.reportTools({
          for (final tool in state.tools.activeTools())
            tool.name: tool.sourceLabel,
        });
      } catch (_) {}
      if (!mounted || connection != _connection) return;
      if (snapshot['stopped'] != true &&
          snapshot['denialReason'] == null &&
          (snapshot['access'] as Map?)?['approved'] == true) {
        try {
          await state.refreshHostModels();
        } catch (_) {}
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Cannot reach Main. Check the connection.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestAccess() async {
    if (_busy || _connection == null) return;
    setState(() => _busy = true);
    try {
      await _connection!.access(request: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Access requested from Main.')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not send the request to Main.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connection?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final access = _snapshot?['access'] as Map?;
    final usage = _snapshot?['usage'] as Map?;
    final remainingQuota = _snapshot?['remaining'] as Map?;
    final expiry = DateTime.tryParse('${access?['expires']}');
    final String status;
    if (_connection == null) {
      status = 'Connect this PC to Main to use its AI.';
    } else if (_error != null) {
      status = _error!;
    } else if (_snapshot == null) {
      status = 'Checking access to Main…';
    } else if (_snapshot!['stopped'] == true) {
      status = 'Main has paused access.';
    } else if (_snapshot?['denialReason'] is String) {
      status = _snapshot!['denialReason'] as String;
    } else if (access?['blocked'] == true) {
      status = 'This PC is blocked by Main.';
    } else if (access?['approved'] != true) {
      status = 'Waiting for Main to approve this PC.';
    } else if (expiry != null && !DateTime.now().isBefore(expiry)) {
      status = 'Access expired. Request more access from Main.';
    } else {
      final limit = access?['requestsPerDay'] as int?;
      final requestsLeft =
          remainingQuota?['requests'] as int? ??
          (limit == null
              ? null
              : max(0, limit - ((usage?['requests'] as int?) ?? 0)));
      final tokensLeft = remainingQuota?['tokens'] as int?;
      final remaining =
          '${requestsLeft == null ? '' : ' · $requestsLeft requests left'}${tokensLeft == null ? '' : ' · $tokensLeft tokens left'}${remainingQuota?['tokensReserved'] == true ? ' (includes an active request reservation)' : ''}';
      final path = (_snapshot?['via'] as List? ?? [])
          .map((v) => (v as Map)['name'])
          .join(' → ');
      status =
          'Connected to ${_snapshot?['main'] ?? state.connectedHostName ?? 'Main'}${path.isEmpty ? '' : ' · via $path'}$remaining'
          '${expiry == null ? '' : ' · until ${expiry.toLocal()}'}';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(status, style: const TextStyle(fontSize: 13)),
                ),
                if (_connection == null)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ConnectScreen(),
                      ),
                    ),
                    child: const Text('Connect to Main'),
                  )
                else ...[
                  IconButton(
                    tooltip: 'Refresh access',
                    onPressed: _busy ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _requestAccess,
                    child: const Text('Request access'),
                  ),
                ],
              ],
            ),
          ),
        ),
        ClientUpdateBanner(
          windowsUpdate: _snapshot?['windowsUpdate'] is Map
              ? Map<String, dynamic>.from(_snapshot!['windowsUpdate'] as Map)
              : null,
        ),
      ],
    );
  }
}

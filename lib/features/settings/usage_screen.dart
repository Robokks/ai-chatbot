import 'package:material_ui/material_ui.dart';

import '../../core/device_stats.dart';
import '../../core/theme.dart';
import '../../core/usage.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../chat/model_picker.dart';
import 'local_models_screen.dart';

/// Device memory/storage, space used by the app, and API usage totals.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, this.deviceStats});

  /// Overrides the device lookup (tests, screenshots).
  final DeviceStats? deviceStats;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  late Future<_Snapshot> _snapshot = _load();
  bool _last30Days = false;

  Future<_Snapshot> _load() async {
    final state = AppScope.read(context);
    final results = await Future.wait([
      widget.deviceStats != null ? Future.value(widget.deviceStats!) : readDeviceStats(),
      AppState.localSupported
          ? state.localModels.bytesOnDisk().catchError((_) => 0)
          : Future.value(0),
      state.storage.chatDataBytes(),
    ]);
    return _Snapshot(results[0] as DeviceStats, results[1] as int, results[2] as int);
  }

  void _refresh() => setState(() => _snapshot = _load());

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    final since = _last30Days ? DateTime.now().subtract(const Duration(days: 30)) : null;
    final usage = usageByModel(state.conversations, since: since).entries.toList()
      ..sort((a, b) => b.value.outputTokens.compareTo(a.value.outputTokens));
    final totalCost = usage.fold<double?>(null, (sum, e) {
      final c = e.value.cost;
      return c == null ? sum : (sum ?? 0) + c;
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Usage & storage'),
        actions: [
          IconButton(tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: FutureBuilder<_Snapshot>(
        future: _snapshot,
        builder: (context, snap) {
          final s = snap.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _Section('This device'),
                      _Card(children: [
                        if (s == null)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else ...[
                          if (s.device.name != null) _Line('Device', s.device.name!),
                          _Meter(
                            label: 'Memory (RAM)',
                            used: s.device.totalRamMb == null || s.device.freeRamMb == null
                                ? null
                                : (s.device.totalRamMb! - s.device.freeRamMb!) << 20,
                            total: s.device.totalRamMb == null ? null : s.device.totalRamMb! << 20,
                          ),
                          _Meter(
                            label: 'Storage',
                            used: s.device.totalDiskBytes == null || s.device.freeDiskBytes == null
                                ? null
                                : s.device.totalDiskBytes! - s.device.freeDiskBytes!,
                            total: s.device.totalDiskBytes,
                          ),
                        ],
                      ]),
                      const _Section('Used by this app'),
                      _Card(children: [
                        if (AppState.localSupported)
                          ListTile(
                            leading: const Icon(Icons.offline_bolt_outlined),
                            title: const Text('On-device models'),
                            subtitle: Text(s == null
                                ? '…'
                                : '${formatBytes(s.modelBytes)} · '
                                    '${state.localModels.installed.length} downloaded'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute<void>(
                                  builder: (_) => const LocalModelsScreen()));
                              _refresh();
                            },
                          ),
                        ListTile(
                          leading: const Icon(Icons.chat_bubble_outline_rounded),
                          title: const Text('Chats & attachments'),
                          subtitle: Text(s == null
                              ? '…'
                              : '${formatBytes(s.chatBytes)} · ${state.conversations.length} chats'),
                          trailing: TextButton(
                            onPressed: state.conversations.isEmpty ? null : _confirmDeleteChats,
                            child: const Text('Delete all'),
                          ),
                        ),
                      ]),
                      Row(
                        children: [
                          const Expanded(child: _Section('AI usage')),
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(value: false, label: Text('All time')),
                                ButtonSegment(value: true, label: Text('30 days')),
                              ],
                              selected: {_last30Days},
                              showSelectedIcon: false,
                              style: const ButtonStyle(visualDensity: VisualDensity.compact),
                              onSelectionChanged: (v) => setState(() => _last30Days = v.first),
                            ),
                          ),
                        ],
                      ),
                      _Card(children: [
                        if (usage.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text('No replies yet.', style: TextStyle(color: p.textMuted)),
                          )
                        else ...[
                          for (final e in usage)
                            ListTile(
                              leading: e.key.$1 == null
                                  ? const Icon(Icons.smart_toy_outlined)
                                  : ProviderAvatar(kind: e.key.$1!, size: 30),
                              title: Text(e.key.$1 == ProviderKind.local
                                  ? state.localModels.byId(e.key.$2)?.name ?? e.key.$2
                                  : prettyModel(e.key.$2)),
                              subtitle: Text(
                                '${e.value.replies} ${e.value.replies == 1 ? 'reply' : 'replies'} · '
                                '${formatTokens(e.value.inputTokens)} in · '
                                '${formatTokens(e.value.outputTokens)} out',
                              ),
                              trailing: e.value.cost == null
                                  ? null
                                  : Text(formatCost(e.value.cost!),
                                      style: const TextStyle(fontWeight: FontWeight.w600)),
                            ),
                          if (totalCost != null) ...[
                            const Divider(),
                            ListTile(
                              title: const Text('Estimated Claude cost'),
                              trailing: Text(formatCost(totalCost),
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ],
                      ]),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                        child: Text(
                          'Counted from the chats saved on this device, so deleting a chat '
                          'removes its usage too. Costs use list prices and are shown for '
                          'Claude models only; on-device models are free.',
                          style: TextStyle(color: p.textMuted, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteChats() async {
    final state = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all chats?'),
        content: Text('All ${state.conversations.length} chats and their attachments will be '
            'permanently deleted from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.deleteAllChats();
      _refresh();
    }
  }
}

class _Snapshot {
  const _Snapshot(this.device, this.modelBytes, this.chatBytes);
  final DeviceStats device;
  final int modelBytes;
  final int chatBytes;
}

class _Meter extends StatelessWidget {
  const _Meter({required this.label, required this.used, required this.total});

  final String label;
  final int? used;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final t = total, u = used;
    final fraction = t == null || u == null || t == 0 ? null : (u / t).clamp(0.0, 1.0);
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
              Text(
                t == null
                    ? 'Not reported'
                    : u == null
                        ? '${formatBytes(t)} total'
                        : '${formatBytes(t - u)} free of ${formatBytes(t)}',
                style: TextStyle(color: p.textMuted, fontSize: 13),
              ),
            ],
          ),
          if (fraction != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: p.surfaceHigh,
                color: fraction > 0.9 ? Theme.of(context).colorScheme.error : accent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: TextStyle(color: Palette.of(context).textMuted, fontSize: 13)),
            ),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
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
      child: Material(type: MaterialType.transparency, child: Column(children: children)),
    );
  }
}

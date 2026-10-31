import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/device_stats.dart';
import '../../core/theme.dart';
import '../../core/usage.dart';
import '../../data/llm/local_provider.dart';
import '../../data/local/image_engine.dart';
import '../../data/local/local_models.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';

/// Download, import and remove GGUF models that run offline on this device.
class LocalModelsScreen extends StatefulWidget {
  const LocalModelsScreen({super.key, this.deviceStats});

  /// Overrides the device lookup (tests, screenshots).
  final DeviceStats? deviceStats;

  @override
  State<LocalModelsScreen> createState() => _LocalModelsScreenState();
}

class _LocalModelsScreenState extends State<LocalModelsScreen> {
  late final Future<DeviceStats> _device =
      widget.deviceStats != null ? Future.value(widget.deviceStats) : readDeviceStats();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final store = state.localModels;
    final p = Palette.of(context);

    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('On-device models'),
          actions: [
            IconButton(
              tooltip: 'Add a model',
              onPressed: () => _addCustom(context, store),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: p.surfaceHigh,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.offline_bolt_outlined, color: p.textMuted),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'These models run entirely on this device: no internet and no API '
                              'key after the download. They are smaller than cloud models, so '
                              'answers are simpler. Use Wi-Fi to download.',
                              style: TextStyle(fontSize: 13.5, color: p.text, height: 1.45),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    FutureBuilder<DeviceStats>(
                      future: _device,
                      builder: (context, snap) => _DeviceSummary(stats: snap.data),
                    ),
                    const SizedBox(height: 12),
                    for (final m in store.chatModels)
                      LocalModelCard(
                        device: _device,
                        info: m,
                        selected: state.provider == ProviderKind.local && state.model == m.id,
                      ),
                    if (store.imageModels.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
                        child: Text('Image models (for Create images)',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600, color: p.textMuted)),
                      ),
                      for (final m in store.imageModels)
                        LocalModelCard(device: _device, info: m, selected: false),
                    ],
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: () => _addCustom(context, store),
                      icon: const Icon(Icons.add_link_rounded),
                      label: const Text('Add a GGUF model (link or file)'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addCustom(BuildContext context, LocalModelStore store) async {
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a model'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Paste a Hugging Face link to a .gguf file. Q4_K_M files around '
                  '0.5–2 GB work best on phones.'),
              const SizedBox(height: 8),
              Text(
                'Only add models from sources you trust: a malicious model file can '
                'harm the app.',
                style: TextStyle(fontSize: 13, color: Theme.of(ctx).colorScheme.error),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'hf://owner/repo/model-Q4_K_M.gguf',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'file'),
            child: const Text('Pick a file instead'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'link'),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    try {
      if (choice == 'link' && controller.text.trim().isNotEmpty) {
        final m = LocalModelInfo.fromLink(controller.text);
        await store.addCustom(m);
        _startDownload(messenger, store, m);
      } else if (choice == 'file') {
        final files = await FilePicker.pickFiles(dialogTitle: 'Pick a .gguf model');
        if (files.isEmpty) return;
        final f = files.first;
        if (f.path == null || !f.name.toLowerCase().endsWith('.gguf')) {
          throw const FormatException('Pick a .gguf file');
        }
        await store.importFile(f.path!, f.name);
      }
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not add model: $e')));
    }
  }
}

void _startDownload(
    ScaffoldMessengerState messenger, LocalModelStore store, LocalModelInfo m) {
  store.download(m).then((_) {
    messenger.showSnackBar(SnackBar(content: Text('${m.name} is ready to use offline')));
  }, onError: (Object e) {
    if (e is DownloadCancelled) return;
    messenger.showSnackBar(SnackBar(content: Text('${m.name}: $e')));
  });
}

String _megabytes(int mb) =>
    mb >= 1000 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '$mb MB';

/// One model with its download, use and delete buttons. Also used on the
/// Create images screen.
class LocalModelCard extends StatelessWidget {
  const LocalModelCard({
    super.key,
    required this.device,
    required this.info,
    required this.selected,
  });

  final Future<DeviceStats> device;
  final LocalModelInfo info;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final store = state.localModels;
    final installed = store.installed.contains(info.id);
    final progress = store.progress[info.id];
    final status = store.status[info.id];
    final interrupted = store.interrupted.contains(info.id);
    final custom = store.custom.contains(info);
    final p = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final downloading = progress != null;
    final details = [
      if (info.sizeMb > 0) _megabytes(info.sizeMb),
      if (info.ramGb > 0) 'needs ~${info.ramGb.toStringAsFixed(info.ramGb % 1 == 0 ? 0 : 1)} GB RAM',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: selected ? accent : p.border, width: selected ? 1.5 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(info.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                        ),
                        if (installed) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.check_circle_rounded,
                              size: 16, color: Color(0xFF2E9E5B)),
                        ],
                      ],
                    ),
                    if (details.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(details,
                            style: TextStyle(color: p.textMuted, fontSize: 12.5)),
                      ),
                    if (!installed)
                      FutureBuilder<DeviceStats>(
                        future: device,
                        builder: (context, snap) => snap.hasData
                            ? _FitChip(
                                fit: modelFit(snap.data!, ramGb: info.ramGb, sizeMb: info.sizeMb))
                            : const SizedBox.shrink(),
                      ),
                    if (info.note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(info.note, style: const TextStyle(fontSize: 13.5)),
                      ),
                    if (info.license != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('Open source · ${info.license!.name} license',
                            style: TextStyle(color: p.textMuted, fontSize: 12)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (downloading)
                TextButton(onPressed: () => store.cancel(info.id), child: const Text('Cancel'))
              else if (installed) ...[
                if (!selected && !info.isImage)
                  FilledButton(
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
                    onPressed: () {
                      state.selectModel(ProviderKind.local, info.id);
                      Navigator.of(context).pop();
                    },
                    child: const Text('Use'),
                  ),
                PopupMenuButton<String>(
                  onSelected: (_) => _delete(context),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete from device')),
                  ],
                ),
              ] else if (interrupted) ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
                  onPressed: () => _startDownload(ScaffoldMessenger.of(context), store, info),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Resume'),
                ),
                IconButton(
                  tooltip: 'Discard partial download',
                  onPressed: () => store.discardPartial(info.id),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ] else ...[
                if (info.url.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _startDownload(ScaffoldMessenger.of(context), store, info),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Download'),
                  ),
                if (custom)
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: () => store.removeCustom(info.id),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
              ],
            ],
          ),
          if (downloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 10, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress == 0 ? null : progress,
                        minHeight: 6,
                        backgroundColor: p.surfaceHigh,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(progress == 0 ? 'Starting…' : '${(progress * 100).round()}%',
                      style: TextStyle(color: p.textMuted, fontSize: 12.5)),
                ],
              ),
            ),
          if (downloading)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                status ?? 'Keeps downloading if you switch apps',
                style: TextStyle(color: p.textMuted, fontSize: 12.5),
              ),
            ),
          if (interrupted && !downloading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Download stopped. Resume continues from where it left off.',
                style: TextStyle(color: p.textMuted, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final store = AppScope.read(context).localModels;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${info.name}?'),
        content: const Text('The file is removed from this device. You can download it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final path = await store.pathFor(info.id);
    await LocalEngineHost.instance.release(path);
    await ImageEngineHost.instance.release(path);
    await store.delete(info.id);
  }
}

/// "This phone: 8 GB RAM (3.1 GB free) · 54 GB storage free".
class _DeviceSummary extends StatelessWidget {
  const _DeviceSummary({required this.stats});

  final DeviceStats? stats;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = stats;
    final parts = <String>[
      if (s?.totalRamMb != null)
        '${formatBytes(s!.totalRamMb! << 20)} RAM'
            '${s.freeRamMb != null ? ' (${formatBytes(s.freeRamMb! << 20)} free)' : ''}',
      if (s?.freeDiskBytes != null) '${formatBytes(s!.freeDiskBytes!)} storage free',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        Icon(Icons.smartphone_rounded, size: 18, color: p.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text('This device: ${parts.join(' · ')}',
              style: TextStyle(color: p.textMuted, fontSize: 13)),
        ),
      ],
    );
  }
}

class _FitChip extends StatelessWidget {
  const _FitChip({required this.fit});

  final ModelFit fit;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (fit) {
      ModelFit.fits => ('Fits this device', const Color(0xFF2E9E5B), Icons.check_rounded),
      ModelFit.tight => ('May be slow on this device', const Color(0xFFB7791F), Icons.speed_rounded),
      ModelFit.tooBig => ('Too big for this device', Theme.of(context).colorScheme.error,
          Icons.block_rounded),
      ModelFit.noSpace => ('Not enough storage', Theme.of(context).colorScheme.error,
          Icons.sd_card_alert_outlined),
      ModelFit.unknown => ('', Colors.transparent, Icons.check_rounded),
    };
    if (fit == ModelFit.unknown) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/llm/local_provider.dart';
import '../../data/local/local_models.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';

/// Download, import and remove GGUF models that run offline on this device.
class LocalModelsScreen extends StatelessWidget {
  const LocalModelsScreen({super.key});

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
                    const SizedBox(height: 16),
                    for (final m in store.all)
                      _ModelCard(
                        info: m,
                        installed: store.installed.contains(m.id),
                        progress: store.progress[m.id],
                        status: store.status[m.id],
                        interrupted: store.interrupted.contains(m.id),
                        selected: state.provider == ProviderKind.local && state.model == m.id,
                        custom: store.custom.contains(m),
                      ),
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

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.info,
    required this.installed,
    required this.progress,
    required this.status,
    required this.interrupted,
    required this.selected,
    required this.custom,
  });

  final LocalModelInfo info;
  final bool installed;
  final double? progress;
  final String? status;
  final bool interrupted;
  final bool selected;
  final bool custom;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final store = state.localModels;
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
                    if (info.note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(info.note, style: const TextStyle(fontSize: 13.5)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (downloading)
                TextButton(onPressed: () => store.cancel(info.id), child: const Text('Cancel'))
              else if (installed) ...[
                if (!selected)
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
                  Text('${((progress ?? 0) * 100).round()}%',
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
    await LocalEngineHost.instance.release(await store.pathFor(info.id));
    await store.delete(info.id);
  }
}

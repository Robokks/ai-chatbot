import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../server/lan_updates.dart';
import '../host/widgets.dart';

/// Root supplies exactly one service, so clients cannot contact GitHub directly.
class LanUpdatesScreen extends StatefulWidget {
  const LanUpdatesScreen({
    super.key,
    this.cache,
    this.client,
    required this.destinationDirectory,
    this.onCacheChanged,
  }) : assert((cache == null) != (client == null));
  final LanUpdateCache? cache;
  final LanUpdateClient? client;
  final Directory destinationDirectory;
  final VoidCallback? onCacheChanged;
  @override
  State<LanUpdatesScreen> createState() => _LanUpdatesScreenState();
}

class _LanUpdatesScreenState extends State<LanUpdatesScreen> {
  LanUpdateManifest? _manifest;
  bool _busy = false;
  String? _status;
  @override
  void initState() {
    super.initState();
    _manifest = widget.cache?.manifest;
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final info = widget.cache != null
          ? await widget.cache!.refresh()
          : await widget.client!.fetchManifest();
      widget.onCacheChanged?.call();
      if (mounted) {
        setState(() {
          _manifest = info;
          _status = 'Update information is ready.';
        });
      }
    } on Object {
      if (mounted) {
        setState(
          () => _status = 'Could not check updates. Check the network, Main access rules, and release availability.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final info = _manifest;
    if (info == null || widget.client == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final file = await widget.client!.downloadTo(
        widget.destinationDirectory,
        info,
      );
      if (mounted) {
        setState(
          () => _status =
              'Verified update saved to ${file.path}. Close the app, unzip it into a new folder, and run ai_chatbot.exe. Keep all extracted files together.',
        );
      }
    } on Object {
      if (mounted) {
        setState(
          () => _status = 'Download failed or the checksum did not match. A different file already in the destination folder must be moved first.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Windows updates')),
    body: PageBody(
      children: [
        const SectionTitle('LAN updates'),
        NoteBox(
          icon: Icons.system_update_alt,
          text: widget.cache != null
              ? 'Main downloads the official Windows release once. Approved PCs can download the verified ZIP over the lab network. Enable the Updates service for each PC first.'
              : 'Download the Windows release cached on Main. The app verifies its size and checksum before saving it. Installation stays manual.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _check,
          child: Text(
            widget.cache != null
                ? 'Refresh Main update cache'
                : 'Check Main for update',
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        if (_manifest case final info?) ...[
          const SizedBox(height: 16),
          CardBox(
            children: [
              ListTile(
                title: Text(info.release),
                subtitle: Text('Published ${info.publishedAt.toLocal()}'),
              ),
              ListTile(
                title: const Text(windowsUpdateFilename),
                subtitle: Text(
                  '${(info.bytes / 1048576).toStringAsFixed(1)} MB',
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText('SHA-256: ${info.sha256Hex}'),
              ),
            ],
          ),
          if (widget.client != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy ? null : _download,
              child: const Text('Download verified ZIP'),
            ),
            Text('Save folder: ${widget.destinationDirectory.path}'),
          ],
        ],
        if (_status != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SelectableText(_status!),
          ),
        const SizedBox(height: 16),
        const Text(
          'This screen reports the cached release, not whether your installed build is current.',
        ),
      ],
    ),
  );
}

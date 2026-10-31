import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/device_stats.dart';
import '../../core/theme.dart';
import '../../data/local/image_engine.dart';
import '../../data/local/image_gallery.dart';
import '../../state/app_state.dart';
import '../../state/image_maker.dart';
import '../settings/local_models_screen.dart';

/// Create images: type a description, get a picture. Pictures stay in a
/// gallery below.
class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key, this.deviceStats});

  /// Overrides the device lookup (tests, screenshots).
  final DeviceStats? deviceStats;

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  final _prompt = TextEditingController();
  late final Future<DeviceStats> _device =
      widget.deviceStats != null ? Future.value(widget.deviceStats) : readDeviceStats();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).images.refresh();
    });
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _make(ImageMaker maker) async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    try {
      await maker.make(_prompt.text);
    } on ImageMakerException catch (e) {
      if (mounted && e.message != 'Stopped.') setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final maker = state.images;
    final p = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;

    return ListenableBuilder(
      listenable: Listenable.merge([maker, maker.gallery, state.localModels]),
      builder: (context, _) {
        final showDownload = maker.localModel == null && maker.unsupported == null;
        return Scaffold(
          appBar: AppBar(title: const Text('Create images')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (maker.hostOffers && (maker.canMakeHere || showDownload)) ...[
                        Text('Make on', style: TextStyle(color: p.textMuted, fontSize: 13)),
                        const SizedBox(height: 6),
                        SegmentedButton<ImageTarget>(
                          segments: [
                            const ButtonSegment(
                                value: ImageTarget.thisDevice,
                                icon: Icon(Icons.smartphone_rounded),
                                label: Text('This device')),
                            ButtonSegment(
                                value: ImageTarget.homeServer,
                                icon: const Icon(Icons.computer_rounded),
                                label: Text(maker.hostName, overflow: TextOverflow.ellipsis)),
                          ],
                          selected: {maker.target},
                          onSelectionChanged: maker.busy ? null : (s) => maker.setTarget(s.first),
                        ),
                        const SizedBox(height: 14),
                      ] else if (maker.hostOffers && !maker.canMakeHere)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text('Pictures are made on ${maker.hostName}.',
                              style: TextStyle(color: p.textMuted, fontSize: 13)),
                        ),
                      if (maker.target == ImageTarget.thisDevice && showDownload) ...[
                        _Info(
                          icon: Icons.download_rounded,
                          text: 'To make pictures on this device, download the image model once '
                              '(Wi-Fi recommended). After that it works without internet.',
                        ),
                        const SizedBox(height: 10),
                        for (final m in state.localModels.imageModels)
                          LocalModelCard(device: _device, info: m, selected: false),
                        const SizedBox(height: 6),
                      ],
                      if (maker.unsupported != null && !maker.hostOffers)
                        _Info(
                          icon: Icons.info_outline_rounded,
                          text: '${maker.unsupported} You can still make pictures with a PC: '
                              'share it from the PC (Settings → Share this device → Share image '
                              'maker), then connect to it here.',
                        ),
                      if (maker.available) ...[
                        TextField(
                          controller: _prompt,
                          enabled: !maker.busy,
                          minLines: 2,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                          decoration: const InputDecoration(
                            hintText: 'Describe the picture, e.g. "a red fox in autumn leaves, '
                                'watercolor"',
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (maker.busy) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                                value: maker.fraction, minHeight: 6, backgroundColor: p.surfaceHigh),
                          ),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: Text(maker.status ?? 'Working…',
                                  style: TextStyle(color: p.textMuted, fontSize: 13)),
                            ),
                            TextButton.icon(
                              onPressed: maker.stop,
                              icon: const Icon(Icons.stop_rounded),
                              label: const Text('Stop'),
                            ),
                          ]),
                        ] else
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 14)),
                            onPressed: () => _make(maker),
                            icon: const Icon(Icons.auto_awesome_rounded),
                            label: const Text('Make image'),
                          ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(_error!,
                                style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          'Pictures are made by AI and can be wrong or strange. Don\'t make '
                          'pictures of real people without their permission.',
                          style: TextStyle(color: p.textMuted, fontSize: 12),
                        ),
                      ],
                      if (maker.gallery.images.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text('Your pictures',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600, color: p.textMuted)),
                        const SizedBox(height: 8),
                        GridView.count(
                          crossAxisCount: MediaQuery.sizeOf(context).width > 600 ? 3 : 2,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            for (final img in maker.gallery.images)
                              _Thumb(
                                key: ValueKey(img.id),
                                image: img,
                                gallery: maker.gallery,
                                accent: accent,
                                onReuse: (prompt) => _prompt.text = prompt,
                              ),
                          ],
                        ),
                      ] else if (maker.available)
                        Padding(
                          padding: const EdgeInsets.only(top: 28),
                          child: Center(
                            child: Text('Your pictures will appear here',
                                style: TextStyle(color: p.textMuted)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: p.surfaceHigh, borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: p.textMuted),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, color: p.text, height: 1.45))),
      ]),
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({
    super.key,
    required this.image,
    required this.gallery,
    required this.accent,
    required this.onReuse,
  });

  final GalleryImage image;
  final ImageGallery gallery;
  final Color accent;
  final void Function(String prompt) onReuse;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<Uint8List?> _bytes = widget.gallery.bytes(widget.image.id);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      label: 'Picture: ${widget.image.prompt}',
      button: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: p.surfaceHigh,
          child: InkWell(
            onTap: () async {
              final bytes = await _bytes;
              if (bytes == null || !context.mounted) return;
              await showImageViewer(context,
                  image: widget.image, bytes: bytes, gallery: widget.gallery, onReuse: widget.onReuse);
            },
            child: FutureBuilder<Uint8List?>(
              future: _bytes,
              builder: (context, snap) => snap.data == null
                  ? Center(
                      child: snap.connectionState == ConnectionState.done
                          ? Icon(Icons.broken_image_outlined, color: p.textMuted)
                          : const SizedBox.shrink(),
                    )
                  : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-size view with Save, Use these words again and Delete.
Future<void> showImageViewer(
  BuildContext context, {
  required GalleryImage image,
  required Uint8List bytes,
  ImageGallery? gallery,
  void Function(String prompt)? onReuse,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final p = Palette.of(ctx);
      final when = DateFormat.yMMMd().add_jm().format(image.createdAt);
      return Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
                const SizedBox(height: 10),
                if (image.prompt.isNotEmpty) SelectableText(image.prompt),
                const SizedBox(height: 4),
                Text(
                  'Made by AI${image.madeOn.isEmpty ? '' : ' on ${image.madeOn}'} · $when',
                  style: TextStyle(color: p.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
                  if (gallery != null)
                    TextButton.icon(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (c) => AlertDialog(
                            title: const Text('Delete this picture?'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('Cancel')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('Delete')),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        await gallery.delete(image.id);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Delete'),
                    ),
                  if (onReuse != null && image.prompt.isNotEmpty)
                    TextButton.icon(
                      onPressed: () {
                        onReuse(image.prompt);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.replay_rounded),
                      label: const Text('Use words again'),
                    ),
                  FilledButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      try {
                        final uri = await FilePicker.saveFile(
                            fileName: image.fileName, bytes: bytes, mimeType: 'image/png');
                        if (uri != null) {
                          messenger?.showSnackBar(const SnackBar(content: Text('Picture saved')));
                        }
                      } catch (e) {
                        messenger?.showSnackBar(SnackBar(content: Text('Could not save: $e')));
                      }
                    },
                    icon: const Icon(Icons.save_alt_rounded),
                    label: const Text('Save'),
                  ),
                ]),
              ],
            ),
          ),
        ),
      );
    },
  );
}

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../attachments/attachment_service.dart';
import 'attachment_chip.dart';
import 'model_picker.dart';

/// The message input card: text field, attachments, model pill, send/stop.
class Composer extends StatefulWidget {
  const Composer({super.key, this.autofocus = false, this.hint = 'Reply…'});

  final bool autofocus;
  final String hint;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _service = AttachmentService();
  final List<Attachment> _attachments = [];
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    _focus.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Sets the text, e.g. from a suggestion chip.
  void setText(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    _focus.requestFocus();
  }

  /// Adds files dropped onto the window (desktop drag-and-drop).
  Future<void> addFiles(Future<List<Attachment>> Function() load) async {
    setState(() => _processing = true);
    try {
      final files = await load();
      if (mounted) setState(() => _attachments.addAll(files));
    } on AttachmentException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Could not attach file: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!enterToSend || e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool get _canSend =>
      !_processing && (_controller.text.trim().isNotEmpty || _attachments.isNotEmpty);

  void _send() {
    final state = AppScope.read(context);
    if (state.isStreaming || !_canSend) return;
    HapticFeedback.lightImpact();
    state.send(_controller.text, List.of(_attachments));
    _controller.clear();
    setState(_attachments.clear);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openAttachMenu() async {
    final p = Palette.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            // Tiles size to their content instead of filling the sheet.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasCamera) _AttachOption(icon: Icons.photo_camera_outlined, label: 'Camera', value: 'camera'),
              _AttachOption(icon: Icons.photo_library_outlined, label: 'Photos', value: 'photos'),
              _AttachOption(icon: Icons.attach_file_rounded, label: 'Files', value: 'files'),
            ].map((w) => Expanded(child: w)).toList(),
          ),
        ),
      ),
      backgroundColor: p.surface,
    );
    switch (choice) {
      case 'camera':
        await addFiles(() async {
          final a = await _service.takePhoto();
          return a == null ? <Attachment>[] : [a];
        });
      case 'photos':
        await addFiles(_service.pickPhotos);
      case 'files':
        await addFiles(_service.pickFiles);
    }
  }

  String? _warningFor(Attachment a, ProviderKind provider) {
    if (a.kind == AttachmentKind.image && !provider.images) {
      return '${provider.label} can\'t read images; it will be skipped.';
    }
    if (a.kind == AttachmentKind.pdf && !provider.pdf && a.text == null) {
      return 'No text found in this PDF for ${provider.label}.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final streaming = state.isStreaming;

    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topLeft,
            child: _attachments.isEmpty && !_processing
                ? const SizedBox(width: double.infinity)
                : SizedBox(
                    height: 80,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(6, 8, 6, 4),
                      children: [
                        for (final a in _attachments)
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: AttachmentChip(
                              attachment: a,
                              warning: _warningFor(a, state.provider),
                              onRemove: () => setState(() => _attachments.remove(a)),
                            ),
                          ),
                        if (_processing)
                          const Center(
                            child: SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: widget.autofocus,
            minLines: 1,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            style: Theme.of(context).textTheme.bodyLarge,
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: TextStyle(color: p.textMuted),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            ),
          ),
          Row(
            children: [
              _RoundIcon(
                icon: Icons.add_rounded,
                tooltip: 'Add photos & files',
                onTap: _openAttachMenu,
                bordered: true,
              ),
              const Spacer(),
              const ModelPill(),
              const SizedBox(width: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                child: streaming
                    ? _RoundIcon(
                        key: const ValueKey('stop'),
                        icon: Icons.stop_rounded,
                        tooltip: 'Stop',
                        onTap: state.stop,
                        filled: p.text,
                        iconColor: p.background,
                      )
                    : _RoundIcon(
                        key: const ValueKey('send'),
                        icon: Icons.arrow_upward_rounded,
                        tooltip: 'Send',
                        onTap: _canSend ? _send : null,
                        filled: _canSend ? accent : accent.withValues(alpha: 0.35),
                        iconColor: Colors.white,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AttachOption extends StatelessWidget {
  const _AttachOption({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: p.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.pop(context, value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 26),
                const SizedBox(height: 8),
                Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.filled,
    this.iconColor,
    this.bordered = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? filled;
  final Color? iconColor;
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled ?? Colors.transparent,
        shape: CircleBorder(
          side: bordered ? BorderSide(color: p.border) : BorderSide.none,
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 38,
            child: Icon(icon, size: 21, color: iconColor ?? p.text),
          ),
        ),
      ),
    );
  }
}

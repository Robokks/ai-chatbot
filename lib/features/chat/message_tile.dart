import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import 'attachment_chip.dart';
import 'markdown_view.dart';
import 'model_picker.dart';
import 'tool_calls_view.dart';
import 'usage_sheet.dart';

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isLast,
    required this.streaming,
  });

  final Message message;
  final bool isLast;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    return switch (message.role) {
      Role.user => _UserMessage(message: message, editable: isLast || _isLastUser(context)),
      Role.assistant => _AssistantMessage(message: message, isLast: isLast, streaming: streaming),
      // Shown inside the assistant turn that called the tools.
      Role.tool => const SizedBox.shrink(),
    };
  }

  bool _isLastUser(BuildContext context) {
    final c = AppScope.read(context).current;
    if (c == null) return false;
    return c.messages.lastWhere((m) => m.role == Role.user,
            orElse: () => message) ==
        message;
  }
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.message, required this.editable});

  final Message message;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8, left: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (message.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in message.attachments) AttachmentChip(attachment: a),
                ],
              ),
            ),
          if (message.text.isNotEmpty)
            GestureDetector(
              onLongPress: () => _showActions(context),
              onSecondaryTap: () => _showActions(context),
              child: Container(
                constraints: BoxConstraints(maxWidth: width * 0.85),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  color: p.userBubble,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: SelectableText(
                  message.text,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showActions(BuildContext context) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                _copy(context, message.text);
              },
            ),
            if (editable)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit and resend'),
                onTap: () {
                  Navigator.pop(ctx);
                  _edit(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final state = AppScope.read(context);
    final controller = TextEditingController(text: message.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 10,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      state.editAndResend(message, result);
    }
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.message,
    required this.isLast,
    required this.streaming,
  });

  final Message message;
  final bool isLast;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final waiting = streaming && message.text.isEmpty && message.toolCalls.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.reasoning.isNotEmpty)
            _ThinkingSection(text: message.reasoning, active: waiting),
          if (waiting && message.reasoning.isEmpty) const _ThinkingDots(),
          if (message.text.isNotEmpty) MarkdownView(message.text),
          if (message.toolCalls.isNotEmpty) ToolCallsView(message: message, streaming: streaming),
          if (message.error != null)
            _ErrorCard(
              message: message.error!,
              onRetry: isLast && !streaming ? AppScope.read(context).regenerate : null,
            ),
          if (!streaming && message.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  _ActionIcon(
                    icon: Icons.copy_rounded,
                    tooltip: 'Copy',
                    onTap: () => _copy(context, message.text),
                  ),
                  if (isLast)
                    _ActionIcon(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Regenerate',
                      onTap: AppScope.read(context).regenerate,
                    ),
                  const SizedBox(width: 8),
                  if (message.model != null)
                    Flexible(
                      child: Text(
                        AppScope.read(context).localModels.byId(message.model!)?.name ??
                            prettyModel(message.model!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textMuted, fontSize: 12),
                      ),
                    ),
                  if (UsageSummary.textFor(message) != null) ...[
                    Text('  ·  ', style: TextStyle(color: p.textMuted, fontSize: 12)),
                    Flexible(flex: 2, child: UsageSummary(message: message)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

void _copy(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  HapticFeedback.selectionClick();
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(
      content: Text('Copied to clipboard'),
      duration: Duration(seconds: 1),
      width: 220,
    ));
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      color: Palette.of(context).textMuted,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class _ThinkingSection extends StatefulWidget {
  const _ThinkingSection({required this.text, required this.active});

  final String text;
  final bool active;

  @override
  State<_ThinkingSection> createState() => _ThinkingSectionState();
}

class _ThinkingSectionState extends State<_ThinkingSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.psychology_alt_outlined, size: 18, color: p.textMuted),
                    const SizedBox(width: 8),
                    Text(
                      widget.active ? 'Thinking…' : 'Thought process',
                      style: TextStyle(color: p.textMuted, fontSize: 13.5),
                    ),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.expand_more_rounded, size: 20, color: p.textMuted),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _open
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Text(
                        widget.text.trim(),
                        style: TextStyle(color: p.textMuted, fontSize: 13.5, height: 1.5),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pulsing accent mark shown while waiting for the first token.
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final status = AppScope.of(context).streamingStatus;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text(status,
                    style: TextStyle(color: Palette.of(context).textMuted, fontSize: 14)),
              ),
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Opacity(
                  opacity: 0.25 +
                      0.75 *
                          (1 - ((_c.value * 3 - i) % 3 - 0.5).abs().clamp(0, 1)),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 20, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

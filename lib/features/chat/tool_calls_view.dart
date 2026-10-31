import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../../tools/tool_source.dart';

/// The tools an assistant turn used, each expandable to its input and result.
class ToolCallsView extends StatelessWidget {
  const ToolCallsView({super.key, required this.message, required this.streaming});

  final Message message;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final msgs = state.current?.messages ?? const <Message>[];
    final i = msgs.indexOf(message);
    final results = <String, ToolResult>{
      if (i >= 0 && i + 1 < msgs.length && msgs[i + 1].role == Role.tool)
        for (final r in msgs[i + 1].toolResults) r.callId: r,
    };
    final running = state.isStreaming && i == msgs.length - 1;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in message.toolCalls)
            _ToolCallTile(
              call: c,
              result: results[c.id],
              running: running && results[c.id] == null,
              source: state.tools.configFor(c.name)?.name,
            ),
        ],
      ),
    );
  }
}

class _ToolCallTile extends StatefulWidget {
  const _ToolCallTile({required this.call, this.result, required this.running, this.source});

  final ToolCall call;
  final ToolResult? result;
  final bool running;
  final String? source;

  @override
  State<_ToolCallTile> createState() => _ToolCallTileState();
}

class _ToolCallTileState extends State<_ToolCallTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final r = widget.result;
    final error = r?.isError ?? false;
    final Widget leading = widget.running
        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(
            r == null
                ? Icons.build_outlined
                : error
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
            size: 18,
            color: error ? Theme.of(context).colorScheme.error : p.textMuted,
          );
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: widget.running ? 'Running ' : 'Used ',
                          style: TextStyle(color: p.textMuted),
                        ),
                        TextSpan(
                          text: widget.call.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (widget.source != null)
                          TextSpan(text: '  ·  ${widget.source}', style: TextStyle(color: p.textMuted)),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5),
                    ),
                  ),
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 20, color: p.textMuted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Label('Input'),
                  _Code(prettyJson(widget.call.arguments)),
                  if (r != null) ...[
                    const SizedBox(height: 8),
                    _Label(error ? 'Error' : 'Result'),
                    _Code(r.text.length > 4000 ? '${r.text.substring(0, 4000)}…' : r.text),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: TextStyle(color: Palette.of(context).textMuted, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

class _Code extends StatelessWidget {
  const _Code(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: p.codeBackground, borderRadius: BorderRadius.circular(8)),
      child: SelectableText(text, style: mono(size: 12.5, color: p.text)),
    );
  }
}

/// Asks the user to allow a tool run (always for CLI programs).
class ToolApprovalCard extends StatelessWidget {
  const ToolApprovalCard({super.key, required this.request});

  final ToolApprovalRequest request;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final p = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.shield_outlined, color: accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Allow ${request.spec.sourceLabel} to run?',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(child: _Code(request.preview)),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => state.answerApproval(false), child: const Text('Deny')),
              const SizedBox(width: 6),
              FilledButton(onPressed: () => state.answerApproval(true), child: const Text('Allow')),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../attachments/attachment_service.dart';
import 'composer.dart';
import 'message_tile.dart';
import 'tool_calls_view.dart';

const _maxContentWidth = 760.0;

/// The conversation view, or the welcome screen for a new chat.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.leading});

  /// Menu button on mobile / sidebar toggle on desktop.
  final Widget? leading;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();
  final _composerKey = GlobalKey<ComposerState>();
  bool _pinnedToBottom = true;
  bool _dragging = false;
  Conversation? _shown;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      // The list is reversed, so offset 0 is the newest message.
      final pinned = _scroll.offset < 80;
      if (pinned != _pinnedToBottom) setState(() => _pinnedToBottom = pinned);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final c = state.current;
    if (!identical(c, _shown)) {
      _shown = c;
      _pinnedToBottom = true;
    }

    Widget body = Column(
      children: [
        _TopBar(leading: widget.leading, title: c?.title),
        Expanded(
          child: c == null || c.messages.isEmpty
              ? _Welcome(composerKey: _composerKey)
              : _messages(state, c),
        ),
        if (state.pendingApproval != null)
          _ComposerDock(child: ToolApprovalCard(request: state.pendingApproval!)),
        if (c != null && c.messages.isNotEmpty)
          _ComposerDock(child: Composer(key: _composerKey)),
      ],
    );

    if (isDesktop) {
      body = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          final service = AttachmentService();
          _composerKey.currentState?.addFiles(() async => [
                for (final f in d.files) await service.fromXFile(f),
              ]);
        },
        child: Stack(children: [body, if (_dragging) const _DropOverlay()]),
      );
    }
    return body;
  }

  Widget _messages(AppState state, Conversation c) {
    final msgs = c.messages;
    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          reverse: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final m = msgs[msgs.length - 1 - i];
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                child: MessageTile(
                  key: ValueKey(m.id),
                  message: m,
                  isLast: i == 0,
                  streaming: identical(state.streamingMessage, m),
                ),
              ),
            );
          },
        ),
        Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: Center(
            child: AnimatedScale(
              scale: _pinnedToBottom ? 0 : 1,
              duration: const Duration(milliseconds: 160),
              child: _ScrollDownButton(onTap: _jumpToBottom),
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({this.leading, this.title});

  final Widget? leading;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            const SizedBox(width: 4),
            ?leading,
            Expanded(
              child: Text(
                title ?? '',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
            ),
            IconButton(
              tooltip: 'New chat',
              onPressed: title == null ? null : state.newChat,
              icon: const Icon(Icons.edit_square),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _ComposerDock extends StatelessWidget {
  const _ComposerDock({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.composerKey});

  final GlobalKey<ComposerState> composerKey;

  static const _suggestions = [
    (Icons.edit_note_rounded, 'Write', 'Help me write a polite follow-up email'),
    (Icons.school_outlined, 'Learn', 'Explain how transformers work in simple terms'),
    (Icons.code_rounded, 'Code', 'Write a Python script that renames files by date'),
    (Icons.lightbulb_outline_rounded, 'Brainstorm', 'Give me 10 weekend project ideas'),
  ];

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return 'Up late?';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final state = AppScope.of(context);
    final needsKey = !state.hasKey(state.provider);

    final greeting = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome, color: accent, size: wide ? 34 : 28),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                _greeting(),
                textAlign: TextAlign.center,
                style: serif(context, size: wide ? 40 : 32),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'How can I help you today?',
          style: TextStyle(color: p.textMuted, fontSize: 16),
        ),
      ],
    );

    Widget chip((IconData, String, String) s) => ActionChip(
          avatar: Icon(s.$1, size: 18, color: p.textMuted),
          label: Text(s.$2),
          onPressed: () => composerKey.currentState?.setText(s.$3),
          backgroundColor: p.background,
          side: BorderSide(color: p.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        );

    final composer = Composer(
      key: composerKey,
      autofocus: wide,
      hint: 'How can I help you today?',
    );

    if (!wide) {
      // Phone: greeting in the middle, suggestions and composer at the bottom.
      return SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      minHeight: MediaQuery.sizeOf(context).height * 0.45),
                  child: Center(child: greeting),
                ),
              ),
            ),
            if (needsKey)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _KeyBanner(provider: state.provider),
              ),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _suggestions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => Center(child: chip(_suggestions[i])),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: composer,
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 24),
                  greeting,
                  const SizedBox(height: 32),
                  if (needsKey) _KeyBanner(provider: state.provider),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [for (final s in _suggestions) chip(s)],
                  ),
                  const SizedBox(height: 20),
                  composer,
                  const SizedBox(height: 96),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyBanner extends StatelessWidget {
  const _KeyBanner({required this.provider});

  final ProviderKind provider;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: p.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.key_rounded, size: 20, color: p.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Add your ${provider.label} API key to start chatting.',
                style: const TextStyle(fontSize: 14)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
            child: const Text('Settings'),
          ),
        ],
      ),
    );
  }
}

class _ScrollDownButton extends StatelessWidget {
  const _ScrollDownButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Material(
      color: p.surface,
      shape: CircleBorder(side: BorderSide(color: p.border)),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.arrow_downward_rounded, size: 20),
        ),
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accent, width: 2),
          ),
          alignment: Alignment.center,
          child: Text('Drop files to attach',
              style: serif(context, size: 24).copyWith(color: accent)),
        ),
      ),
    );
  }
}

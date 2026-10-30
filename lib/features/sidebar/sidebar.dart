import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';

/// Conversation history: new chat, search, grouped list, settings.
class Sidebar extends StatefulWidget {
  const Sidebar({super.key, this.onNavigate, this.onCollapse});

  /// Called after a selection (closes the drawer on mobile).
  final VoidCallback? onNavigate;

  /// Shown as a collapse button on desktop.
  final VoidCallback? onCollapse;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  String _query = '';

  Map<String, List<Conversation>> _group(List<Conversation> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final groups = <String, List<Conversation>>{};
    for (final c in items) {
      final d = c.updatedAt;
      final day = DateTime(d.year, d.month, d.day);
      final diff = today.difference(day).inDays;
      final label = switch (diff) {
        <= 0 => 'Today',
        1 => 'Yesterday',
        < 7 => 'Previous 7 days',
        < 30 => 'Previous 30 days',
        _ => 'Older',
      };
      groups.putIfAbsent(label, () => []).add(c);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final q = _query.toLowerCase();
    final items = q.isEmpty
        ? state.conversations
        : state.conversations.where((c) =>
            c.title.toLowerCase().contains(q) ||
            c.messages.any((m) => m.text.toLowerCase().contains(q))).toList();
    final groups = _group(items);

    return Container(
      color: p.sidebar,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Text('Chatbot', style: serif(context, size: 22, weight: FontWeight.w600)),
                  const Spacer(),
                  if (widget.onCollapse != null)
                    IconButton(
                      tooltip: 'Close sidebar',
                      onPressed: widget.onCollapse,
                      icon: Icon(Icons.view_sidebar_outlined, color: p.textMuted),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _SidebarButton(
                icon: Icons.add_rounded,
                iconBackground: accent,
                label: 'New chat',
                onTap: () {
                  state.newChat();
                  widget.onNavigate?.call();
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: SizedBox(
                height: 40,
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search chats',
                    prefixIcon: Icon(Icons.search_rounded, size: 20, color: p.textMuted),
                    contentPadding: EdgeInsets.zero,
                    fillColor: p.background,
                  ),
                ),
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          q.isEmpty ? 'Your chats will appear here' : 'No matching chats',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.textMuted),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      children: [
                        for (final e in groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
                            child: Text(
                              e.key,
                              style: TextStyle(
                                color: p.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          for (final c in e.value)
                            _ConversationTile(
                              conversation: c,
                              selected: identical(state.current, c),
                              onTap: () {
                                state.open(c);
                                widget.onNavigate?.call();
                              },
                            ),
                        ],
                      ],
                    ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(8),
              child: _SidebarButton(
                icon: Icons.settings_outlined,
                label: 'Settings',
                onTap: () {
                  widget.onNavigate?.call();
                  Navigator.of(context).pushNamed('/settings');
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconBackground,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconBackground;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: iconBackground,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon,
                    size: 20, color: iconBackground == null ? null : Colors.white),
              ),
              const SizedBox(width: 10),
              Text(label, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? p.surfaceHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: () => _menu(context),
          onSecondaryTap: () => _menu(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    conversation.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                if (selected)
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _menu(context),
                    child: Icon(Icons.more_horiz_rounded, size: 18, color: p.textMuted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context) async {
    final state = AppScope.read(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'rename') {
      final controller = TextEditingController(text: conversation.title);
      final title = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Rename chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (title != null) state.rename(conversation, title);
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete chat?'),
          content: Text('"${conversation.title}" will be permanently deleted.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok == true) state.delete(conversation);
    }
  }
}

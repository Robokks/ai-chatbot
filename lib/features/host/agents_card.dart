import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../server/agent_hub.dart';
import '../../server/coding_agents.dart';
import 'widgets.dart';

/// Host screen card: share Claude Code / Codex and pick their folders.
class AgentsCard extends StatefulWidget {
  const AgentsCard({super.key, required this.hub});
  final AgentHub hub;

  @override
  State<AgentsCard> createState() => _AgentsCardState();
}

class _AgentsCardState extends State<AgentsCard> {
  AgentHub get hub => widget.hub;

  @override
  void initState() {
    super.initState();
    // After the first frame, so the hub's notify doesn't land mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) => hub.ensureDetected());
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CardBox(children: [
        for (final a in CodingAgent.values)
          SwitchListTile(
            value: hub.settings.enabled.contains(a) && hub.versions[a] != null,
            onChanged: hub.versions[a] == null ? null : (v) => hub.setEnabled(a, v),
            secondary: const Icon(Icons.terminal_rounded),
            title: Text(a.label),
            subtitle: Text(
              !hub.versions.containsKey(a)
                  ? 'Looking…'
                  : hub.versions[a] ?? 'Not found on this PC. ${a.installHint}',
              style: TextStyle(color: p.textMuted),
            ),
          ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.refresh_rounded, size: 20),
          title: const Text('Check again'),
          onTap: hub.detecting ? null : hub.refresh,
        ),
      ]),
      const SizedBox(height: 12),
      CardBox(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text('Project folders they may work in',
              style: TextStyle(fontWeight: FontWeight.w600, color: p.text)),
        ),
        if (hub.settings.folders.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Add at least one folder.', style: TextStyle(color: p.textMuted)),
          ),
        for (final f in hub.settings.folders)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(f.label),
            subtitle: Text(f.path, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              DropdownButton<bool>(
                value: f.canEdit,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: false, child: Text('Read only')),
                  DropdownMenuItem(value: true, child: Text('Can edit files')),
                ],
                onChanged: (v) => hub.setCanEdit(f, v ?? false),
              ),
              IconButton(
                tooltip: 'Remove',
                onPressed: () => hub.removeFolder(f),
                icon: const Icon(Icons.close_rounded),
              ),
            ]),
          ),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('Add folder'),
          onTap: () async {
            final path = await FilePicker.getDirectoryPath(dialogTitle: 'Project folder');
            if (path != null) await hub.addFolder(path);
          },
        ),
      ]),
      const SizedBox(height: 10),
      NoteBox(
        icon: Icons.verified_user_outlined,
        text: 'Paired devices can ask Claude Code or Codex to work in these folders. '
            'You approve each run here first. Runs use your own Claude / ChatGPT '
            'sign-in on this PC. On the other device, add Settings → Tools → '
            '"Tools from <this PC>" (open it again after changing folders here).'
            '${hub.trusting ? '\n\nAllowing all runs until '
                '${TimeOfDay.fromDateTime(hub.allowAllUntil!).format(context)}.' : ''}',
      ),
      if (hub.trusting)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: hub.stopTrusting, child: const Text('Ask again for every run')),
        ),
    ]);
  }
}

/// Approval box for coding-agent runs, shown above every screen.
class AgentApprovalOverlay extends StatelessWidget {
  const AgentApprovalOverlay({super.key, required this.hub, required this.child});
  final AgentHub hub;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => Stack(children: [
        child,
        if (hub.pending.isNotEmpty)
          Positioned(
            left: 12,
            right: 12,
            top: MediaQuery.paddingOf(context).top + 12,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: _ApprovalCard(hub: hub, approval: hub.pending.first),
              ),
            ),
          ),
      ]),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.hub, required this.approval});
  final AgentHub hub;
  final HostApproval approval;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final a = approval;
    return Material(
      elevation: 8,
      color: p.surface,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Icon(Icons.terminal_rounded),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${a.device} wants to run ${a.agent.label}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            if (hub.pending.length > 1) Text('+${hub.pending.length - 1} more', style: TextStyle(color: p.textMuted)),
          ]),
          const SizedBox(height: 6),
          Text('Folder: ${a.folder} · ${a.canEdit ? 'can edit files' : 'read only'}',
              style: TextStyle(color: p.textMuted)),
          const SizedBox(height: 10),
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: p.surfaceHigh, borderRadius: BorderRadius.circular(10)),
            child: SingleChildScrollView(child: Text(a.task)),
          ),
          const SizedBox(height: 12),
          Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
            TextButton(onPressed: () => hub.answer(a, false), child: const Text('Deny')),
            OutlinedButton(
              onPressed: () => hub.answer(a, true, trustMinutes: 30),
              child: const Text('Allow for 30 min'),
            ),
            FilledButton(onPressed: () => hub.answer(a, true), child: const Text('Allow')),
          ]),
        ]),
      ),
    );
  }
}

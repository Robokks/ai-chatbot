import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/llm/auto_provider.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../chat/model_picker.dart';
import 'settings_screen.dart';

/// Free Auto: the order of free providers, each with its model.
class FreeAutoScreen extends StatefulWidget {
  const FreeAutoScreen({super.key});

  @override
  State<FreeAutoScreen> createState() => _FreeAutoScreenState();
}

class _FreeAutoScreenState extends State<FreeAutoScreen> {
  late final AppState _state = AppScope.read(context);
  late List<AutoRoute> _routes = _state.autoRoutes;

  Future<void> _save() async {
    await _state.saveAutoRoutes(_routes);
    setState(() => _routes = _state.autoRoutes);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    final last = state.autoCooldowns.lastUsed;
    final missing = [
      for (final k in defaultAutoOrder)
        if (!_routes.any((r) => r.kind == k)) k,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Free Auto')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(
            'Free Auto tries these free providers from the top. When one says its limit is '
            'reached or fails before answering, it moves to the next. A provider that hit its '
            'limit rests for 15 minutes. Drag to change the order.',
            style: TextStyle(color: p.textMuted, fontSize: 13.5, height: 1.4),
          ),
          if (last != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Last answer: ${last.$1.label} · ${prettyModel(last.$2)}',
                  style: const TextStyle(fontSize: 13.5)),
            ),
          const SizedBox(height: 12),
          if (_routes.isEmpty)
            Text('No free providers yet. Add a free key below.', style: TextStyle(color: p.textMuted)),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (a, b) {
              _routes.insert(b, _routes.removeAt(a));
              _save();
            },
            children: [
              for (final (i, r) in _routes.indexed)
                Card(
                  key: ValueKey(r.kind),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
                    child: Row(children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(Icons.drag_indicator_rounded, color: p.textMuted),
                        ),
                      ),
                      ProviderAvatar(kind: r.kind, size: 28),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(r.kind.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                          DropdownButton<String>(
                            value: r.model,
                            isExpanded: true,
                            isDense: true,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final m in {r.model, ...?state.providers[r.kind]?.models})
                                if (isFreeModel(r.kind, m))
                                  DropdownMenuItem(
                                    value: m,
                                    child: Text(prettyModel(m),
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 13, color: p.textMuted)),
                                  ),
                            ],
                            onChanged: (m) {
                              if (m == null) return;
                              r.model = m;
                              _save();
                            },
                          ),
                          if (state.autoCooldowns.until(r.kind) case final t?)
                            Text('Limit reached · back at ${DateFormat.jm().format(t)}',
                                style: const TextStyle(color: Color(0xFFB7791F), fontSize: 12)),
                        ]),
                      ),
                      Switch(
                        value: r.enabled,
                        onChanged: (v) {
                          r.enabled = v;
                          _save();
                        },
                      ),
                    ]),
                  ),
                ),
            ],
          ),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Add more free providers', style: TextStyle(color: p.textMuted, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final k in missing)
                ActionChip(
                  avatar: ProviderAvatar(kind: k, size: 18),
                  label: Text(k.label),
                  onPressed: () async {
                    await Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => ProviderScreen(kind: k)));
                    if (mounted) setState(() => _routes = _state.autoRoutes);
                  },
                ),
            ]),
            for (final k in [ProviderKind.openrouter, ProviderKind.together, ProviderKind.chutes])
              if (missing.contains(k) && state.hasKey(k))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      '${k.label} is used only with its free models. Open ${k.label}, tap "Test & '
                      'load models" and choose some marked free.',
                      style: TextStyle(color: p.textMuted, fontSize: 12.5)),
                ),
          ],
        ],
      ),
    );
  }
}

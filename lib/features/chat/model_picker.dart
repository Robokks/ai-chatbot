import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../host/connect_screen.dart';
import '../settings/free_auto_screen.dart';
import '../setup/setup_wizard.dart';
import '../settings/local_models_screen.dart';
import '../settings/settings_screen.dart';

/// Compact model selector shown in the composer.
class ModelPill extends StatelessWidget {
  const ModelPill({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => showModelPicker(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                state.provider == ProviderKind.local
                    ? state.localModels.byId(state.model)?.name ?? state.model
                    : prettyModel(state.model),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.textMuted,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: p.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// "claude-sonnet-5-5" → "Claude Sonnet 5.5"; other ids are returned as is.
String prettyModel(String id) {
  // Home-server and OpenRouter ids look like "anthropic/claude-sonnet-5-5".
  if (id.contains('/')) id = id.substring(id.lastIndexOf('/') + 1);
  final m = RegExp(r'^claude-([a-z]+)-(\d+)(?:-(\d+))?$').firstMatch(id);
  if (m == null) return id;
  final family = m[1]![0].toUpperCase() + m[1]!.substring(1);
  return 'Claude $family ${m[2]}${m[3] != null ? '.${m[3]}' : ''}';
}

Future<void> showModelPicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (ctx, scroll) => _ModelList(scroll: scroll),
    ),
  );
}

class _ModelList extends StatelessWidget {
  const _ModelList({required this.scroll});

  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final available = ProviderKind.values.where(
      (k) => k != ProviderKind.local || AppState.localSupported,
    );
    // Free Auto first, then the providers you have keys for. The rest are
    // folded under "More providers" so the list stays short.
    final ready = [
      if (state.hasKey(ProviderKind.auto)) ProviderKind.auto,
      ...available.where((k) => k != ProviderKind.auto && state.hasKey(k)),
    ];
    final always = {ProviderKind.local, ProviderKind.network};
    final kinds = [
      ...ready,
      ...available.where((k) => always.contains(k) && !state.hasKey(k)),
    ];
    final more = available
        .where((k) => !state.hasKey(k) && !always.contains(k) && k != ProviderKind.auto)
        .toList();
    String label(ProviderKind k, String m) => k == ProviderKind.local
        ? state.localModels.byId(m)?.name ?? m
        : k == ProviderKind.auto
            ? 'Free Auto (best free model that works)'
            : prettyModel(m);

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text('Choose a model', style: serif(context, size: 22)),
        ),
        if (ready.isEmpty || ready.every((k) => k == ProviderKind.local))
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                openSetupWizard(context);
              },
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Get free AI in 2 minutes'),
            ),
          ),
        for (final k in kinds) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
            child: Row(
              children: [
                ProviderAvatar(kind: k, size: 22),
                const SizedBox(width: 10),
                Text(
                  k.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 6),
                Text(
                  k.vendor,
                  style: TextStyle(color: p.textMuted, fontSize: 12.5),
                ),
                const Spacer(),
                if (k == ProviderKind.network)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const ConnectScreen()));
                    },
                    child: Text(state.hasKey(k) ? 'Manage' : 'Connect'),
                  )
                else if (k == ProviderKind.local)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const LocalModelsScreen(),
                        ),
                      );
                    },
                    child: Text(state.hasKey(k) ? 'Manage' : 'Download'),
                  )
                else if (k == ProviderKind.auto)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const FreeAutoScreen()));
                    },
                    child: const Text('Order'),
                  )
                else if (!state.hasKey(k))
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ProviderScreen(kind: k),
                        ),
                      );
                    },
                    child: const Text('Add key'),
                  ),
              ],
            ),
          ),
          if (state.hasKey(k))
            for (final m in state.providers[k]!.models)
              _ModelTile(
                label: label(k, m),
                selected: state.provider == k && state.model == m,
                accent: accent,
                onTap: () {
                  state.selectModel(k, m);
                  Navigator.pop(context);
                },
              ),
        ],
        if (more.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text('More providers (${more.length})',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  '${more.where((k) => k.free).length} of them have free plans. Tap one to add a key.',
                  style: TextStyle(color: p.textMuted, fontSize: 12.5)),
              children: [
                for (final k in more)
                  ListTile(
                    dense: true,
                    leading: ProviderAvatar(kind: k, size: 22),
                    title: Text(k.label),
                    subtitle: k.free
                        ? Text('Free · ${k.freeNote}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFF2E9E5B), fontSize: 12))
                        : null,
                    trailing: const Text('Add key'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => ProviderScreen(kind: k)));
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? p.surfaceHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 15)),
                ),
                if (selected)
                  Icon(Icons.check_rounded, color: accent, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small colored badge with the provider's initial.
class ProviderAvatar extends StatelessWidget {
  const ProviderAvatar({super.key, required this.kind, this.size = 28});

  final ProviderKind kind;
  final double size;

  static const _colors = {
    ProviderKind.anthropic: Color(0xFFD97757),
    ProviderKind.openai: Color(0xFF10A37F),
    ProviderKind.deepseek: Color(0xFF4D6BFE),
    ProviderKind.gemini: Color(0xFF4285F4),
    ProviderKind.openrouter: Color(0xFF6566F1),
    ProviderKind.groq: Color(0xFFF55036),
    ProviderKind.local: Color(0xFF3F7D58),
    ProviderKind.network: Color(0xFF8A6D3B),
    ProviderKind.custom: Color(0xFF7A7A7A),
    ProviderKind.cerebras: Color(0xFFF15A29),
    ProviderKind.mistral: Color(0xFFFA520F),
    ProviderKind.github: Color(0xFF24292F),
    ProviderKind.nvidia: Color(0xFF76B900),
    ProviderKind.huggingface: Color(0xFFE8A317),
    ProviderKind.cloudflare: Color(0xFFF38020),
    ProviderKind.cohere: Color(0xFF39594D),
    ProviderKind.sambanova: Color(0xFFEE7624),
    ProviderKind.zai: Color(0xFF2D5BFF),
    ProviderKind.freellmapi: Color(0xFF5B5BD6),
    ProviderKind.chutes: Color(0xFF111111),
    ProviderKind.together: Color(0xFF0F6FFF),
    ProviderKind.scaleway: Color(0xFF4F0599),
    ProviderKind.ovh: Color(0xFF123F6D),
    ProviderKind.qwen: Color(0xFF615CED),
    ProviderKind.deepinfra: Color(0xFF2B6CB0),
    ProviderKind.auto: Color(0xFF2E9E5B),
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _colors[kind],
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: kind == ProviderKind.local || kind == ProviderKind.auto
          ? Icon(
              kind == ProviderKind.auto ? Icons.auto_awesome_rounded : Icons.offline_bolt_rounded,
              color: Colors.white,
              size: size * 0.62,
            )
          : Text(
              kind.label[0],
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: size * 0.5,
              ),
            ),
    );
  }
}

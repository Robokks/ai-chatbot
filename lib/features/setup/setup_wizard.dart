import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../chat/model_picker.dart';

/// Set when the wizard was finished or skipped, so it doesn't open again by
/// itself.
const setupDoneKey = 'setup.done';

/// Opens the wizard.
Future<void> openSetupWizard(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SetupWizard()));

/// Whether the wizard should open by itself: first start, nothing set up.
bool shouldAutoOpenSetup(AppState state) {
  if (demoMode || state.storage.getSetting(setupDoneKey) != null) return false;
  return !ProviderKind.values.any((k) =>
      k != ProviderKind.custom && k != ProviderKind.auto && state.hasKey(k));
}

class _Step {
  const _Step({
    required this.kind,
    required this.title,
    required this.badge,
    required this.why,
    required this.how,
  });
  final ProviderKind kind;
  final String title;
  final String badge;
  final String why;
  final List<String> how;
}

const _chatSteps = [
  _Step(
    kind: ProviderKind.groq,
    title: 'Groq: fast free chat',
    badge: 'Start here',
    why: 'Very fast answers. Sign-up takes about a minute.',
    how: [
      'Tap "Open Groq" and sign in (Google account is fine).',
      'Tap "Create API Key", give it any name, then "Submit".',
      'Tap the copy button, come back here and tap "Paste".',
    ],
  ),
  _Step(
    kind: ProviderKind.gemini,
    title: 'Gemini: sees pictures and PDFs',
    badge: 'Recommended',
    why: 'Google\'s free key. Understands photos, scans and PDFs.',
    how: [
      'Tap "Open Google AI Studio" and sign in with your Google account.',
      'Tap "Create API key" (accept the terms if asked).',
      'Copy the key, come back here and tap "Paste".',
    ],
  ),
];

const _pictureSteps = [
  _Step(
    kind: ProviderKind.cloudflare,
    title: 'Cloudflare: free pictures',
    badge: 'Optional',
    why: 'Makes good pictures (FLUX) for free, plus more chat models.',
    how: [
      'Tap "Open Cloudflare", sign up (free) and open "API Tokens".',
      'Create Token → use the "Workers AI" template → Continue → Create. Copy the token.',
      'Your Account ID is on the Workers AI page under "Use REST API". Copy it too.',
    ],
  ),
  _Step(
    kind: ProviderKind.huggingface,
    title: 'Hugging Face: free pictures',
    badge: 'Optional',
    why: 'Another way to make free FLUX pictures (small monthly allowance).',
    how: [
      'Tap "Open Hugging Face", sign up and open Access Tokens.',
      'Create new token → type "Read" → Create. Copy it.',
      'Come back here and tap "Paste".',
    ],
  ),
];

/// "Free AI in 2 minutes": step-by-step free keys, each checked right away.
class SetupWizard extends StatefulWidget {
  const SetupWizard({super.key});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  late final AppState _state = AppScope.read(context);
  bool _cloudflare = true;

  Future<void> _finish({required bool done}) async {
    final navigator = Navigator.of(context);
    await _state.storage.setSetting(setupDoneKey, done ? 'done' : 'skipped');
    if (done && _state.hasKey(ProviderKind.auto)) {
      await _state.selectModel(ProviderKind.auto, 'auto');
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = Palette.of(context);
    final ready = state.hasKey(ProviderKind.auto);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Free AI in 2 minutes'),
        actions: [
          TextButton(onPressed: () => _finish(done: false), child: const Text('Skip')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Get free keys from AI companies. No credit card. Each key is checked right away '
                    'and kept encrypted on this device.',
                    style: TextStyle(color: p.textMuted, fontSize: 14, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  for (final (i, s) in _chatSteps.indexed) _StepCard(number: i + 1, step: s),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
                    child: Row(children: [
                      Expanded(
                        child: Text('3. Pictures (optional)',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: true, label: Text('Cloudflare')),
                          ButtonSegment(value: false, label: Text('Hugging Face')),
                        ],
                        selected: {_cloudflare},
                        onSelectionChanged: (v) => setState(() => _cloudflare = v.first),
                      ),
                    ]),
                  ),
                  _StepCard(
                    key: ValueKey(_cloudflare),
                    number: 3,
                    step: _cloudflare ? _pictureSteps[0] : _pictureSteps[1],
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    onPressed: ready ? () => _finish(done: true) : null,
                    icon: const Icon(Icons.check_rounded),
                    label: Text(ready ? 'Done: start chatting with Free Auto' : 'Add one key to finish'),
                  ),
                  if (ready)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        [
                          'Ready: chat with Free Auto',
                          if (state.autoCanSee) 'photos and PDFs are understood',
                          if (state.images.available) 'free pictures in Create images',
                        ].join(' · '),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF2E9E5B), fontSize: 13),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'More free companies (Cerebras, Mistral, NVIDIA, …) are in Settings → Free AI. '
                    'Use one account per company.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.textMuted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepCard extends StatefulWidget {
  const _StepCard({super.key, required this.number, required this.step});
  final int number;
  final _Step step;

  @override
  State<_StepCard> createState() => _StepCardState();
}

class _StepCardState extends State<_StepCard> {
  late final AppState _state = AppScope.read(context);
  late final _key = TextEditingController(text: _state.keyFor(widget.step.kind));
  late final _account = TextEditingController(
      text: RegExp(r'/accounts/([^/{}]+)/').firstMatch(_state.providers[k]!.baseUrl)?.group(1) ?? '');
  bool _busy = false;
  String? _status;
  bool _ok = false;

  ProviderKind get k => widget.step.kind;

  @override
  void initState() {
    super.initState();
    if (_state.hasKey(k)) {
      _ok = true;
      _status = 'Connected';
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _account.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _status = 'Nothing copied yet. Copy the key on the website first.');
      return;
    }
    _key.text = text;
    await _check();
  }

  Future<void> _check() async {
    final key = _key.text.trim();
    if (key.isEmpty) return;
    if (k.needsAccountId && _account.text.trim().isEmpty) {
      setState(() {
        _ok = false;
        _status = 'Also paste your Account ID.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Checking…';
    });
    try {
      final s = _state.providers[k]!;
      if (k.needsAccountId) {
        await _state.updateProviderSettings(ProviderSettings(
            kind: k,
            baseUrl: k.baseUrl.replaceFirst('{account}', _account.text.trim()),
            models: s.models));
      }
      await _state.setKey(k, key);
      final found = await _state.fetchModels(k);
      // Keep the suggested models that exist; otherwise take the key's own.
      final keep = [for (final m in s.models) if (found.contains(m)) m];
      if (keep.isEmpty && found.isNotEmpty) {
        await _state.updateProviderSettings(ProviderSettings(
            kind: k, baseUrl: _state.providers[k]!.baseUrl, models: found.take(10).toList()));
      }
      setState(() {
        _ok = true;
        _status = 'Works · ${found.length} models';
      });
    } catch (e) {
      await _state.setKey(k, '');
      setState(() {
        _ok = false;
        _status = 'Not accepted: $e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = widget.step;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _ok ? const Color(0xFF2E9E5B) : p.border, width: _ok ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          ProviderAvatar(kind: k, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${widget.number}. ${s.title}',
                style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: p.surfaceHigh, borderRadius: BorderRadius.circular(8)),
            child: Text(s.badge, style: TextStyle(fontSize: 11.5, color: p.textMuted)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(s.why, style: TextStyle(color: p.textMuted, fontSize: 13)),
        const SizedBox(height: 8),
        for (final (i, line) in s.how.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${String.fromCharCode(97 + i)}) $line', style: const TextStyle(fontSize: 13.5)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(k.keyUrl), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text('Open ${k == ProviderKind.gemini ? 'Google AI Studio' : k.label}'),
          ),
        ),
        if (k.needsAccountId)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: _account,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Account ID', isDense: true),
            ),
          ),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: '${k.label} key', isDense: true),
              onSubmitted: (_) => _check(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: _busy ? null : _paste,
            child: const Text('Paste'),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            onPressed: _busy ? null : _check,
            child: const Text('Check'),
          ),
        ]),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              if (_busy)
                const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(_ok ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                    size: 16,
                    color: _ok ? const Color(0xFF2E9E5B) : Theme.of(context).colorScheme.error),
              const SizedBox(width: 6),
              Expanded(child: Text(_status!, style: const TextStyle(fontSize: 13))),
            ]),
          ),
      ]),
    );
  }
}

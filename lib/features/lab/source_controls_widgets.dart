import 'package:material_ui/material_ui.dart';

import '../../data/llm/named_sources.dart';

Future<void> editSourceQuota(
  BuildContext context,
  NamedSources catalog,
  NamedSource source,
) => showDialog<void>(
  context: context,
  builder: (_) => _QuotaEditor(catalog: catalog, source: source),
);

class _QuotaEditor extends StatefulWidget {
  const _QuotaEditor({required this.catalog, required this.source});
  final NamedSources catalog;
  final NamedSource source;
  @override
  State<_QuotaEditor> createState() => _QuotaEditorState();
}

class _QuotaEditorState extends State<_QuotaEditor> {
  final requests = TextEditingController(),
      tokens = TextEditingController(),
      minutes = TextEditingController();
  int scope = -1;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  void load() {
    final p = scope == -1
        ? widget.source.quota
        : widget.source.keyQuotas[scope] ?? QuotaPolicy();
    requests.text = p.requests?.toString() ?? '';
    tokens.text = p.tokens?.toString() ?? '';
    minutes.text = '${p.windowSeconds ~/ 60}';
  }

  @override
  void dispose() {
    requests.dispose();
    tokens.dispose();
    minutes.dispose();
    super.dispose();
  }

  int? positive(String text) {
    if (text.trim().isEmpty) return null;
    final value = int.tryParse(text.trim());
    if (value == null || value < 1) {
      throw const FormatException(
        'Enter positive whole numbers, or leave a limit blank.',
      );
    }
    return value;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.source.name} limits'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'These are your configured limits, not a provider allowance. Source and key limits both apply. Windows align to UTC time. Unreported usage keeps the full token reservation until reset.',
            ),
            DropdownButtonFormField<int>(
              initialValue: scope,
              decoration: const InputDecoration(labelText: 'Limit applies to'),
              items: [
                const DropdownMenuItem(value: -1, child: Text('Whole source')),
                for (var i = 0; i < widget.catalog.keyCount(widget.source); i++)
                  DropdownMenuItem(value: i, child: Text('Key ${i + 1}')),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    scope = v;
                    load();
                  });
                }
              },
            ),
            TextField(
              controller: requests,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Requests per window (blank = unlimited)',
              ),
            ),
            TextField(
              controller: tokens,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Tokens per window (blank = unlimited)',
                helperText: 'Input and output count. A conservative input allowance is reserved before sending.',
              ),
            ),
            TextField(
              controller: minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Reset window in minutes',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.catalog.quotaSummary(
                widget.source,
                scope == -1 ? null : scope,
              ),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () async {
          try {
            final window = positive(minutes.text);
            if (window == null) {
              throw const FormatException('Enter a reset window.');
            }
            final policy = QuotaPolicy(
              requests: positive(requests.text),
              tokens: positive(tokens.text),
              windowSeconds: window * 60,
            )..validate();
            if (scope == -1) {
              widget.source.quota = policy;
            } else {
              widget.source.keyQuotas[scope] = policy;
            }
            await widget.catalog.save(widget.source);
            if (context.mounted) Navigator.pop(context);
          } on FormatException catch (e) {
            setState(() => error = e.message);
          }
        },
        child: const Text('Save limits'),
      ),
    ],
  );
}

Future<void> editModelOptions(
  BuildContext context,
  NamedSources catalog,
  NamedSource source,
  String model,
) => showDialog<void>(
  context: context,
  builder: (_) => _ModelEditor(catalog: catalog, source: source, model: model),
);

class _ModelEditor extends StatefulWidget {
  const _ModelEditor({
    required this.catalog,
    required this.source,
    required this.model,
  });
  final NamedSources catalog;
  final NamedSource source;
  final String model;
  @override
  State<_ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends State<_ModelEditor> {
  late final options = ModelOptions.fromJson(
    (widget.source.modelOptions[widget.model] ?? ModelOptions()).toJson(),
  );
  late final contextTokens = TextEditingController(
    text: options.contextTokens?.toString() ?? '',
  );
  String? error;
  @override
  void dispose() {
    contextTokens.dispose();
    super.dispose();
  }

  Widget capability(String label, bool? value, ValueChanged<bool?> update) =>
      DropdownButtonFormField<String>(
        initialValue: value == null
            ? 'unknown'
            : value
            ? 'yes'
            : 'no',
        decoration: InputDecoration(labelText: label),
        items: const [
          DropdownMenuItem(value: 'unknown', child: Text('Unknown')),
          DropdownMenuItem(value: 'yes', child: Text('Supported')),
          DropdownMenuItem(value: 'no', child: Text('Not supported')),
        ],
        onChanged: (v) =>
            setState(() => update(v == 'unknown' ? null : v == 'yes')),
      );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.model),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter capabilities confirmed by your provider. Unknown values stay unknown; filters only include confirmed matches.',
            ),
            SwitchListTile(
              title: const Text('Model enabled'),
              value: options.enabled,
              onChanged: (v) => setState(() => options.enabled = v),
            ),
            capability('Vision', options.vision, (v) => options.vision = v),
            capability('Tools', options.tools, (v) => options.tools = v),
            TextField(
              controller: contextTokens,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Context tokens (blank = unknown)',
              ),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () async {
          final text = contextTokens.text.trim();
          final number = int.tryParse(text);
          if (text.isNotEmpty && (number == null || number < 1)) {
            setState(
              () => error = 'Enter a positive context size or leave it blank.',
            );
            return;
          }
          options.contextTokens = text.isEmpty ? null : number;
          widget.source.modelOptions[widget.model] = options;
          await widget.catalog.save(widget.source);
          if (context.mounted) Navigator.pop(context);
        },
        child: const Text('Save model'),
      ),
    ],
  );
}

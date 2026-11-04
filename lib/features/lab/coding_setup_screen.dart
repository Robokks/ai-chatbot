import 'package:material_ui/material_ui.dart';

/// Callbacks belong to the app connection lifecycle so closing this page does
/// not kill a coding session. All setup stays on this PC.
class CodingSetupScreen extends StatefulWidget {
  const CodingSetupScreen({
    super.key,
    required this.models,
    required this.startClaude,
    required this.startCodex,
    this.configurePackages,
    this.startLabview,
  });
  final List<String> models;
  final Future<void> Function(String model) startClaude;
  final Future<void> Function(String model) startCodex;
  final Future<void> Function()? configurePackages;
  final Future<void> Function(String model)? startLabview;
  @override
  State<CodingSetupScreen> createState() => _CodingSetupScreenState();
}

class _CodingSetupScreenState extends State<CodingSetupScreen> {
  String? _model;
  bool _busy = false;
  String? _status;
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action();
      if (mounted) setState(() => _status = 'Ready.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Setup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.models.contains(_model)
        ? _model
        : widget.models.firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Coding tools')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Use approved Main models from Claude Code or Codex on this PC.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Your Main key stays in the app. Coding tools connect through a local proxy. Existing personal settings are preserved.',
          ),
          const SizedBox(height: 24),
          if (widget.models.isEmpty)
            const Text('Connect to Main and request model access first.')
          else
            DropdownButton<String>(
              value: selected,
              isExpanded: true,
              items: [
                for (final model in widget.models)
                  DropdownMenuItem(value: model, child: Text(model)),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _model = value),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy || selected == null
                ? null
                : () => _run(() => widget.startClaude(selected)),
            child: const Text('Open Claude Code'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy || selected == null
                ? null
                : () => _run(() => widget.startCodex(selected)),
            child: const Text('Open Codex'),
          ),
          if (widget.startLabview != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy || selected == null
                  ? null
                  : () => _run(() => widget.startLabview!(selected)),
              child: const Text('Open LabVIEW terminal'),
            ),
          ],
          if (widget.configurePackages != null) ...[
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(widget.configurePackages!),
              child: const Text('Configure package access'),
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_status!),
            ),
        ],
      ),
    );
  }
}

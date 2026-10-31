import 'package:material_ui/material_ui.dart';

import '../../core/device_stats.dart';
import '../../core/theme.dart';
import '../../core/usage.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import 'model_picker.dart';

/// One-line usage under a reply ("24 tok/s" or "1.2k in · 350 out · $0.003").
/// Tapping opens the full details.
class UsageSummary extends StatelessWidget {
  const UsageSummary({super.key, required this.message});

  final Message message;

  static String? textFor(Message m) {
    final u = m.usage;
    if (u == null) return null;
    final parts = <String>[];
    if (m.provider == ProviderKind.local) {
      final tps = u.tokensPerSecond;
      if (tps != null) parts.add('${tps.toStringAsFixed(tps < 10 ? 1 : 0)} tok/s');
      if (u.firstTokenMs != null) parts.add('first word ${formatMs(u.firstTokenMs!)}');
    } else {
      if (u.inputTokens != null) parts.add('${formatTokens(u.inputTokens!)} in');
      if (u.outputTokens != null) parts.add('${formatTokens(u.outputTokens!)} out');
      final cost = costOf(m);
      if (cost != null) parts.add(formatCost(cost));
      if (parts.isEmpty && u.durationMs != null) parts.add(formatMs(u.durationMs!));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final text = textFor(message);
    if (text == null) return const SizedBox.shrink();
    final p = Palette.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => showUsageSheet(context, message),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.textMuted, fontSize: 12),
        ),
      ),
    );
  }
}

Future<void> showUsageSheet(BuildContext context, Message m) {
  final state = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: _UsageDetails(message: m, state: state),
      ),
    ),
  );
}

class _UsageDetails extends StatelessWidget {
  const _UsageDetails({required this.message, required this.state});

  final Message message;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final u = m.usage ?? UsageStats();
    final local = m.provider == ProviderKind.local;
    final cost = costOf(m);
    final modelName = local
        ? state.localModels.byId(m.model ?? '')?.name ?? m.model ?? '—'
        : prettyModel(m.model ?? '—');
    final tps = u.tokensPerSecond;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Reply details', style: serif(context, size: 22)),
        const SizedBox(height: 12),
        _Row('Model', modelName),
        _Row('Provider', m.provider?.label ?? '—'),
        if (u.inputTokens != null)
          _Row('Input tokens',
              '${u.inputTokens}${(u.cachedTokens ?? 0) > 0 ? ' (${u.cachedTokens} cached)' : ''}'),
        if (u.outputTokens != null) _Row('Output tokens', '${u.outputTokens}'),
        if (tps != null) _Row('Speed', '${tps.toStringAsFixed(1)} tokens/second'),
        if (u.firstTokenMs != null) _Row('Time to first word', formatMs(u.firstTokenMs!)),
        if (u.durationMs != null) _Row('Total time', formatMs(u.durationMs!)),
        if (cost != null) _Row('Estimated cost', formatCost(cost)),
        if (local) _LocalMemoryRows(modelId: m.model ?? '', state: state),
        const SizedBox(height: 10),
        Text(
          local
              ? 'Ran on this device. Memory figures are approximate.'
              : cost != null
                  ? 'Cost uses the provider\'s list prices; your actual bill may differ.'
                  : 'Token counts as reported by the provider. Costs are shown for Claude models.',
          style: TextStyle(color: Palette.of(context).textMuted, fontSize: 12.5),
        ),
      ],
    );
  }
}

class _LocalMemoryRows extends StatelessWidget {
  const _LocalMemoryRows({required this.modelId, required this.state});

  final String modelId;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: Future.wait([
        state.localModels.installedBytes(modelId).catchError((_) => null),
        readDeviceStats(),
      ]),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final size = snap.data![0] as int?;
        final d = snap.data![1] as DeviceStats;
        return Column(
          children: [
            if (size != null) _Row('Model in memory', '≈ ${formatBytes(size)}'),
            if (d.freeRamMb != null && d.totalRamMb != null)
              _Row('Phone memory free',
                  '${formatBytes(d.freeRamMb! << 20)} of ${formatBytes(d.totalRamMb! << 20)}'),
          ],
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: TextStyle(color: p.textMuted))),
          const SizedBox(width: 12),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

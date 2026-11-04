import 'package:material_ui/material_ui.dart';

import '../../server/lab_analytics.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, required this.analytics});
  final LabAnalytics analytics;
  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  int days = 1;
  String? deviceId, model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.analytics,
    builder: (context, _) {
      final all = widget.analytics.summary(Duration(days: days));
      final summary = widget.analytics.summary(
        Duration(days: days),
        deviceId: deviceId,
        model: model,
      );
      final devices = all.by((e) => e.deviceId);
      final models = all.by((e) => e.model);
      return Scaffold(
        appBar: AppBar(title: const Text('Analytics')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'Request volume, latency, token usage and failures.',
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final d in [1, 7, 30])
                      ChoiceChip(
                        label: Text(d == 1 ? '24h' : '${d}d'),
                        selected: days == d,
                        onSelected: (_) => setState(() {
                          days = d;
                          deviceId = null;
                          model = null;
                        }),
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Filter PC',
                      onSelected: (v) =>
                          setState(() => deviceId = v.isEmpty ? null : v),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: '', child: Text('All PCs')),
                        for (final e in devices.entries)
                          PopupMenuItem(
                            value: e.key,
                            child: Text(e.value.events.last.device),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          deviceId == null
                              ? 'All PCs ▾'
                              : devices[deviceId]?.events.last.device ??
                                    deviceId!,
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Filter model',
                      onSelected: (v) =>
                          setState(() => model = v.isEmpty ? null : v),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: '',
                          child: Text('All models'),
                        ),
                        for (final m in models.keys)
                          PopupMenuItem(value: m, child: Text(m)),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(model ?? 'All models ▾'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _metric('Requests', '${summary.requests}'),
                    _metric(
                      'Success rate',
                      summary.requests == 0
                          ? '—'
                          : '${(summary.successes * 100 / summary.requests).toStringAsFixed(1)}%',
                    ),
                    _metric(
                      'Input tokens',
                      '${summary.inputTokens ?? '—'}',
                      '${summary.inputSamples}/${summary.requests} requests reported usage',
                    ),
                    _metric(
                      'Output tokens',
                      '${summary.outputTokens ?? '—'}',
                      '${summary.outputSamples}/${summary.requests} requests reported usage',
                    ),
                    _metric('Average latency', _ms(summary.latencyMs)),
                    _metric(
                      'Average first response',
                      _ms(summary.firstTokenMs),
                    ),
                    _metric('Failures', '${summary.failures}'),
                    _metric('Cancelled', '${summary.cancelled}'),
                  ],
                ),
                const SizedBox(height: 24),
                _chart(summary),
                const SizedBox(height: 24),
                _groups(
                  'By PC',
                  summary.by((e) => e.deviceId),
                  (s) => s.events.last.device,
                ),
                _groups(
                  'By model',
                  summary.by((e) => e.model),
                  (s) => s.events.last.model,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Unknown measurements show —. Token totals include only reported usage. No prompts or responses are stored.',
                ),
                const Text(
                  'Metadata is retained for 30 days, up to 30,000 requests.',
                ),
                if (widget.analytics.truncatedBefore != null)
                  Text(
                    'History reached its size limit; requests at or before ${widget.analytics.truncatedBefore!.toLocal()} may be incomplete.',
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
  String _ms(double? n) => n == null ? '—' : '${n.round()} ms';
  Widget _metric(String label, String value, [String? detail]) => Container(
    width: 245,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xffdddddd)),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 12),
        Text(
          value,
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
        ),
        if (detail != null) Text(detail, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
  Widget _groups(
    String title,
    Map<String, LabSummary> groups,
    String Function(LabSummary) label,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 18)),
      if (groups.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No requests in this period.'),
        ),
      for (final group in groups.values)
        ListTile(
          title: Text(label(group)),
          subtitle: Text(
            '${group.successes} succeeded · ${group.failures} failed · ${group.cancelled} cancelled',
          ),
          trailing: Text('${group.requests} requests'),
        ),
    ],
  );
  Widget _chart(LabSummary summary) {
    final now = widget.analytics.clock();
    const bins = 24;
    final width = Duration(days: days).inMilliseconds / bins;
    final good = List<int>.filled(bins, 0), bad = List<int>.filled(bins, 0);
    for (final event in summary.events) {
      final index =
          ((event.time.millisecondsSinceEpoch -
                      now
                          .subtract(Duration(days: days))
                          .millisecondsSinceEpoch) /
                  width)
              .floor()
              .clamp(0, bins - 1);
      if (event.status == 'ok') {
        good[index]++;
      } else {
        bad[index]++;
      }
    }
    final max = List.generate(
      bins,
      (i) => good[i] + bad[i],
    ).fold(1, (a, b) => a > b ? a : b);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffdddddd)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Requests over time'),
          const SizedBox(height: 16),
          SizedBox(
            height: 150,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < bins; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            height: 130 * bad[i] / max,
                            color: const Color(0xffb74b4b),
                          ),
                          Container(
                            height: 130 * good[i] / max,
                            color: const Color(0xff222222),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Last ${days == 1 ? '24 hours' : '$days days'} · black: succeeded · red: failed or cancelled',
          ),
        ],
      ),
    );
  }
}

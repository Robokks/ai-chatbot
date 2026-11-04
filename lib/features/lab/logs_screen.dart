import 'package:material_ui/material_ui.dart';

import '../../state/app_state.dart';
import '../../server/lab_analytics.dart';
import '../host/widgets.dart';

class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key, this.analytics});
  final LabAnalytics? analytics;
  @override
  Widget build(BuildContext context) {
    if (analytics != null) {
      return ListenableBuilder(
        listenable: analytics!,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('Logs')),
          body: PageBody(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'Recent requests. Metadata only; prompts, responses and keys are never logged.',
                ),
              ),
              if (analytics!.recent.isEmpty) const Text('No requests yet.'),
              for (final entry in analytics!.recent)
                ListTile(
                  title: Text('${entry.device} · ${entry.model}'),
                  subtitle: Text(
                    '${entry.time.toLocal()} · ${entry.kind}${entry.durationMs == null ? '' : ' · ${entry.durationMs} ms'}${entry.inputTokens == null ? '' : ' · ${entry.inputTokens} input tokens'}${entry.outputTokens == null ? '' : ' · ${entry.outputTokens} output tokens'}',
                  ),
                  trailing: Text(entry.status),
                ),
            ],
          ),
        ),
      );
    }
    final host = AppScope.of(context).host;
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Logs')),
        body: PageBody(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('Recent requests on this Main PC.'),
            ),
            if (host.server.log.isEmpty) const Text('No requests yet.'),
            for (final entry in host.server.log)
              ListTile(
                title: Text('${entry.device} · ${entry.model}'),
                subtitle: Text(
                  '${entry.time.toLocal()}${entry.outputTokens == null ? '' : ' · ${entry.outputTokens} output tokens'}',
                ),
                trailing: Text(entry.status),
              ),
          ],
        ),
      ),
    );
  }
}

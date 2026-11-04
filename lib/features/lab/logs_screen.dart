import 'package:material_ui/material_ui.dart';
import '../../state/app_state.dart';
import '../host/widgets.dart';

class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final host = AppScope.of(context).host;
    return ListenableBuilder(listenable: host, builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Logs')),
      body: PageBody(children: [
        const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Text('Recent requests on this Main PC.')),
        if (host.server.log.isEmpty) const Text('No requests yet.'),
        for (final entry in host.server.log)
          ListTile(title: Text('${entry.device} · ${entry.model}'),
            subtitle: Text('${entry.time.toLocal()}${entry.outputTokens == null ? '' : ' · ${entry.outputTokens} output tokens'}'),
            trailing: Text(entry.status)),
      ]),
    ));
  }
}

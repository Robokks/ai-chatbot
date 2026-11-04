import 'package:material_ui/material_ui.dart';

import '../../server/host_controller.dart';
import '../../state/app_state.dart';
import '../host/agents_card.dart';
import '../host/widgets.dart';

/// Dedicated entry point for the Main PC's existing coding-agent controls.
class AgentsScreen extends StatelessWidget {
  const AgentsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final host = AppScope.of(context).host;
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Agents')),
        body: PageBody(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'Share Claude Code and Codex from this Main PC. Choose the project folders they can use and approve incoming work.',
              ),
            ),
            if (HostController.agentsSupported)
              AgentsCard(hub: host.agents, error: host.server.mcpError)
            else
              const Text(
                'Coding-agent sharing is available on Windows, Linux and macOS.',
              ),
          ],
        ),
      ),
    );
  }
}

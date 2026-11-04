import 'package:material_ui/material_ui.dart';

import '../../server/client_tools_controller.dart';
import 'coding_setup_screen.dart';

class ClientToolsScreen extends StatelessWidget {
  const ClientToolsScreen({super.key, required this.controller});
  final ClientToolsController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Client coding tools')),
      body: Column(
        children: [
          ListTile(
            title: Text(controller.workspace ?? 'Choose your project folder'),
            trailing: OutlinedButton(
              onPressed: controller.chooseWorkspace,
              child: const Text('Choose folder'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Install Claude Code or Codex on this Windows PC first. Package terminal access uses only Main’s allowed package domains.',
            ),
          ),
          Expanded(
            child: CodingSetupScreen(
              models: controller.models,
              startClaude: (model) =>
                  controller.openCoding(codex: false, model: model),
              startCodex: (model) =>
                  controller.openCoding(codex: true, model: model),
              configurePackages: controller.openPackageTerminal,
              startLabview: controller.openLabview,
            ),
          ),
        ],
      ),
    ),
  );
}

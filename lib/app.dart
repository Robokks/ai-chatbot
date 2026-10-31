import 'package:material_ui/material_ui.dart';

import 'core/theme.dart';
import 'features/home/home_shell.dart';
import 'features/host/agents_card.dart';
import 'features/images/images_screen.dart';
import 'features/settings/settings_screen.dart';
import 'server/host_controller.dart';
import 'state/app_state.dart';

class ChatApp extends StatelessWidget {
  const ChatApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => MaterialApp(
          title: 'Chatbot',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: state.themeMode,
          // Claude Code / Codex run requests from paired devices pop up on
          // top of whatever screen is open.
          builder: HostController.agentsSupported
              ? (context, child) => AgentApprovalOverlay(hub: state.host.agents, child: child!)
              : null,
          routes: {
            '/': (_) => const HomeShell(),
            '/settings': (_) => const SettingsScreen(),
            '/images': (_) => const ImagesScreen(),
          },
        ),
      ),
    );
  }
}

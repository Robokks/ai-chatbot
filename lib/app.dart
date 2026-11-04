import 'features/lab/labview_approval_overlay.dart';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'core/theme.dart';
import 'features/lab/role_picker.dart';
import 'features/home/home_shell.dart';
import 'features/host/agents_card.dart';
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
          theme: buildTheme(Brightness.light, style: state.themeStyle),
          darkTheme: buildTheme(Brightness.dark, style: state.themeStyle),
          themeMode: state.themeMode,
          // Claude Code / Codex run requests from paired devices pop up on
          // top of whatever screen is open.
          builder: HostController.agentsSupported
              ? (context, child) => LabviewApprovalOverlay(
                  hub: state.host.labviewApprovals,
                  child: AgentApprovalOverlay(
                    hub: state.host.agents,
                    child: child!,
                  ),
                )
              : null,
          routes: {
            '/': (_) => const _StartScreen(),
            '/settings': (_) => const SettingsScreen(),
          },
        ),
      ),
    );
  }
}

class _StartScreen extends StatelessWidget {
  const _StartScreen();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (defaultTargetPlatform == TargetPlatform.windows &&
        state.labRole == null) {
      return const RolePicker();
    }
    return const HomeShell();
  }
}

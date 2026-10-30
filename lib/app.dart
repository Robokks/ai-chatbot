import 'package:material_ui/material_ui.dart';

import 'core/theme.dart';
import 'features/home/home_shell.dart';
import 'features/settings/settings_screen.dart';
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
          routes: {
            '/': (_) => const HomeShell(),
            '/settings': (_) => const SettingsScreen(),
          },
        ),
      ),
    );
  }
}

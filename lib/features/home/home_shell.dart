import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../../data/lab_role.dart';
import '../chat/chat_screen.dart';
import '../sidebar/sidebar.dart';
import '../settings/settings_screen.dart';
import '../tools/tools_screen.dart';
import '../lab/clients_screen.dart';
import '../lab/logs_screen.dart';
import '../lab/analytics_screen.dart';
import '../lab/models_screen.dart';
import '../lab/client_status_bar.dart';
import '../lab/sources_screen.dart';
import '../lab/agents_screen.dart';

/// Conversation drawer on phones, app menu and chat history on wide screens.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedPage = 0;

  static const _pages = [
    'Chat',
    'Models',
    'Clients',
    'Tools',
    'Logs',
    'Settings',
    'Analytics',
    'Sources',
    'Agents',
  ];
  static const _icons = [
    Icons.chat_bubble_outline,
    Icons.grid_view_outlined,
    Icons.people_outline,
    Icons.build_outlined,
    Icons.article_outlined,
    Icons.settings_outlined,
    Icons.analytics_outlined,
    Icons.dns_outlined,
    Icons.terminal_outlined,
  ];

  static const _wideBreakpoint = 900.0;
  static const _sidebarWidth = 288.0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final state = AppScope.of(context);
    final pages =
        (state.labRole == LabRole.client || state.labRole == LabRole.relay)
        ? [0, 3, 5]
        : [0, 1, 7, 2, 3, 8, 6, 4, 5];
    if (!pages.contains(_selectedPage)) _selectedPage = 0;

    final Widget content;
    if (wide) {
      content = Row(
        children: [
          SizedBox(
            width: _sidebarWidth,
            child: Material(
              color: Palette.of(context).sidebar,
              child: SafeArea(
                child: Column(
                  children: [
                    Flexible(
                      flex: 3,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          key: const ValueKey('desktop-menu'),
                          children: [
                            for (final i in pages)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: ListTile(
                                  leading: Icon(_icons[i]),
                                  title: Text(_pages[i]),
                                  selected: _selectedPage == i,
                                  selectedColor: Theme.of(context)
                                      .colorScheme
                                      .onPrimary,
                                  selectedTileColor: Theme.of(context)
                                      .colorScheme
                                      .primary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  onTap: () =>
                                      setState(() => _selectedPage = i),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(),
                    if (_selectedPage == 0)
                      Expanded(
                        child: Sidebar(
                          onNavigate: () => setState(() => _selectedPage = 0),
                        ),
                      )
                    else
                      const Spacer(),
                  ],
                ),
              ),
            ),
          ),
          VerticalDivider(width: 1, color: Palette.of(context).border),
          Expanded(
            child: switch (_selectedPage) {
              0 => const ChatScreen(),
              1 => ModelsScreen(
                onChat: () => setState(() => _selectedPage = 0),
              ),
              2 => const ClientsScreen(),
              3 => const ToolsScreen(),
              4 => LogsScreen(analytics: state.host.analytics),
              6 => AnalyticsScreen(analytics: state.host.analytics),
              7 => const SourcesScreen(),
              8 => const AgentsScreen(),
              5 => const SettingsScreen(),
              _ => Scaffold(
                appBar: AppBar(title: Text(_pages[_selectedPage])),
                body: const Center(child: Text('Coming soon')),
              ),
            },
          ),
        ],
      );
    } else {
      content = ChatScreen(
        leading: IconButton(
          tooltip: 'Chats',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          icon: const Icon(Icons.menu_rounded),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            state.newChat,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            state.newChat,
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            Navigator.of(context).pushNamed('/settings'),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: _scaffoldKey,
          drawer: wide
              ? null
              : Drawer(
                  width: MediaQuery.sizeOf(context).width * 0.84,
                  child: Sidebar(onNavigate: () => Navigator.of(context).pop()),
                ),
          body: Column(
            children: [
              if (state.labRole == LabRole.client ||
                  state.labRole == LabRole.relay)
                const SafeArea(bottom: false, child: ClientStatusBar()),
              Expanded(child: content),
            ],
          ),
        ),
      ),
    );
  }
}

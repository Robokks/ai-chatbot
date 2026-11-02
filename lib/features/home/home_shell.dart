import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../chat/chat_screen.dart';
import '../setup/setup_wizard.dart';
import '../sidebar/sidebar.dart';

/// Drawer layout on phones, persistent collapsible sidebar on wide screens.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _sidebarOpen = true;

  @override
  void initState() {
    super.initState();
    // First start with nothing set up: show "Free AI in 2 minutes".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _inTests) return;
      if (shouldAutoOpenSetup(AppScope.read(context))) openSetupWizard(context);
    });
  }

  static bool get _inTests => !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  static const _wideBreakpoint = 900.0;
  static const _sidebarWidth = 288.0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final state = AppScope.read(context);

    final Widget content;
    if (wide) {
      content = Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: _sidebarOpen ? _sidebarWidth : 0,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: _sidebarWidth,
                maxWidth: _sidebarWidth,
                child: Sidebar(onCollapse: () => setState(() => _sidebarOpen = false)),
              ),
            ),
          ),
          if (_sidebarOpen) VerticalDivider(width: 1, color: Palette.of(context).border),
          Expanded(
            child: ChatScreen(
              leading: _sidebarOpen
                  ? const SizedBox(width: 48)
                  : IconButton(
                      tooltip: 'Open sidebar',
                      onPressed: () => setState(() => _sidebarOpen = true),
                      icon: const Icon(Icons.view_sidebar_outlined),
                    ),
            ),
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
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): state.newChat,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): state.newChat,
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
          body: content,
        ),
      ),
    );
  }
}

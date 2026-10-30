import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Warm, paper-like palette inspired by the Claude app.
class Palette {
  const Palette({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.sidebar,
    required this.border,
    required this.text,
    required this.textMuted,
    required this.userBubble,
    required this.codeBackground,
  });

  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color sidebar;
  final Color border;
  final Color text;
  final Color textMuted;
  final Color userBubble;
  final Color codeBackground;

  static const accent = Color(0xFFC96442);
  static const accentDark = Color(0xFFD97757);

  static const light = Palette(
    background: Color(0xFFFAF9F5),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFF0EEE6),
    sidebar: Color(0xFFF5F4ED),
    border: Color(0xFFE5E2D9),
    text: Color(0xFF1F1E1D),
    textMuted: Color(0xFF73726C),
    userBubble: Color(0xFFF0EEE6),
    codeBackground: Color(0xFFF5F4EE),
  );

  static const dark = Palette(
    background: Color(0xFF262624),
    surface: Color(0xFF30302E),
    surfaceHigh: Color(0xFF3A3936),
    sidebar: Color(0xFF1F1E1D),
    border: Color(0xFF45443F),
    text: Color(0xFFF5F4EF),
    textMuted: Color(0xFFA6A39A),
    userBubble: Color(0xFF141413),
    codeBackground: Color(0xFF1C1B1A),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

TextStyle serif(BuildContext context, {double size = 28, FontWeight? weight}) =>
    GoogleFonts.sourceSerif4(
      fontSize: size,
      fontWeight: weight ?? FontWeight.w400,
      color: Palette.of(context).text,
      height: 1.2,
    );

TextStyle mono({double size = 13, Color? color}) =>
    GoogleFonts.jetBrainsMono(fontSize: size, color: color, height: 1.5);

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final accent = brightness == Brightness.dark ? Palette.accentDark : Palette.accent;
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
  ).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    surface: p.background,
    onSurface: p.text,
    onSurfaceVariant: p.textMuted,
    surfaceContainerLowest: p.surface,
    surfaceContainerLow: p.sidebar,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceHigh,
    surfaceContainerHighest: p.surfaceHigh,
    outline: p.border,
    outlineVariant: p.border,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    splashFactory: InkSparkle.splashFactory,
  );
  final text = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: p.text,
    displayColor: p.text,
  );

  return base.copyWith(
    textTheme: text.copyWith(
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.6),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.55),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: p.text,
      titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.sidebar,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.border),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.text,
      contentTextStyle: TextStyle(color: p.background),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.text,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: p.background, fontSize: 12),
    ),
    extensions: [
      GptMarkdownThemeData(
        brightness: brightness,
        linkColor: accent,
        linkHoverColor: accent.withValues(alpha: 0.8),
        hrLineColor: p.border,
        highlightColor: p.codeBackground,
        h1: _heading(28, p.text),
        h2: _heading(23, p.text),
        h3: _heading(19, p.text),
      ),
    ],
  );
}

TextStyle _heading(double size, Color color) => GoogleFonts.sourceSerif4(
    fontSize: size, fontWeight: FontWeight.w600, color: color, height: 1.3);

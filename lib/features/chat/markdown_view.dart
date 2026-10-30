import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';

/// Renders assistant markdown: code blocks with highlighting and copy,
/// tables, LaTeX, lists and links.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final monoFamily = GoogleFonts.jetBrainsMono().fontFamily;
    return GptMarkdown(
      data,
      style: Theme.of(context).textTheme.bodyLarge,
      useDollarSignsForLatex: true,
      onLinkTap: (url, title) => launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication),
      onCodeCopy: (_) => HapticFeedback.selectionClick(),
      styleSheet: GptMarkdownStyleSheet(
        codeBlock: CodeBlockStyle(
          backgroundColor: p.codeBackground,
          borderColor: p.border,
          borderWidth: 1,
          borderRadius: const Radius.circular(12),
          fontFamily: monoFamily,
          fontSize: 13,
          highlightWhileStreaming: true,
          languageStyle: TextStyle(color: p.textMuted, fontSize: 12),
        ),
        inlineCode: InlineCodeStyle(
          fontFamily: monoFamily,
          fontSizeFactor: 0.88,
          color: Palette.of(context) == Palette.dark
              ? const Color(0xFFF0A58A)
              : const Color(0xFFB0472A),
          backgroundColor: p.surfaceHigh,
          borderColor: p.border,
          borderWidth: 0.5,
          borderRadius: const Radius.circular(5),
        ),
        table: TableStyle(
          borderColor: p.border,
          borderRadius: const Radius.circular(10),
          headerBackground: p.surfaceHigh,
          cellPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }
}

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
      onLinkTap: (url, title) => openReplyLink(context, url),
      // Remote images are not fetched automatically: a prompt-injected reply
      // could otherwise leak chat text in an image URL without any tap.
      imageBuilder: (context, url, width, height) => _BlockedImage(url: url),
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

/// Link schemes a reply may open. Others (intent:, tel:, custom app schemes)
/// are blocked because replies can be steered by attached documents.
const allowedLinkSchemes = {'https', 'http', 'mailto'};

bool isAllowedReplyLink(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri != null && allowedLinkSchemes.contains(uri.scheme.toLowerCase());
}

/// Shows the real destination of a link from an AI reply before opening it.
Future<void> openReplyLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  if (!isAllowedReplyLink(url)) {
    messenger.showSnackBar(const SnackBar(content: Text('Blocked an unsafe link')));
    return;
  }
  final uri = Uri.parse(url.trim());
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Open link?'),
      content: SelectableText(uri.toString()),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open')),
      ],
    ),
  );
  if (ok == true) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Placeholder for an image in a reply; loads only after the user taps it.
class _BlockedImage extends StatefulWidget {
  const _BlockedImage({required this.url});

  final String url;

  @override
  State<_BlockedImage> createState() => _BlockedImageState();
}

class _BlockedImageState extends State<_BlockedImage> {
  bool _load = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final uri = Uri.tryParse(widget.url);
    final https = uri != null && uri.scheme == 'https';
    if (_load && https) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          widget.url,
          errorBuilder: (_, _, _) =>
              Text('Image failed to load', style: TextStyle(color: p.textMuted)),
        ),
      );
    }
    return Material(
      color: p.surfaceHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: https ? () => setState(() => _load = true) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, size: 18, color: p.textMuted),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  https ? 'Tap to load image from ${uri.host}' : 'Image blocked',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.textMuted, fontSize: 13.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

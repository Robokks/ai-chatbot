import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/models.dart';

/// Thumbnail for images, file card for documents.
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({super.key, required this.attachment, this.onRemove, this.warning});

  final Attachment attachment;
  final VoidCallback? onRemove;

  /// Shown when the selected provider can't use this attachment.
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final a = attachment;
    final Widget body;
    if (a.kind == AttachmentKind.image && a.bytes != null) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(a.bytes!, width: 64, height: 64, fit: BoxFit.cover),
      );
    } else {
      final (icon, color) = fileStyle(a);
      body = Container(
        width: 168,
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.border),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(
                    '${a.kind == AttachmentKind.pdf ? 'PDF' : _ext(a.name)} · ${_size(a.size)}',
                    style: TextStyle(fontSize: 11.5, color: p.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget chip = body;
    if (warning != null) {
      chip = Tooltip(
        message: warning!,
        child: Stack(
          children: [
            Opacity(opacity: 0.5, child: body),
            const Positioned(
              left: 4,
              bottom: 4,
              child: Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFE0A100)),
            ),
          ],
        ),
      );
    }
    if (onRemove == null) return chip;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        chip,
        Positioned(
          top: -6,
          right: -6,
          child: Material(
            color: p.text,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(Icons.close_rounded, size: 14, color: p.background),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _ext(String name) =>
      name.contains('.') ? name.split('.').last.toUpperCase() : 'FILE';

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// Icon and color for a file card, by type.
(IconData, Color) fileStyle(Attachment a) {
  if (a.kind == AttachmentKind.pdf) return (Icons.picture_as_pdf_rounded, const Color(0xFFE5484D));
  final ext = a.name.contains('.') ? a.name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'docx' || 'docm' || 'odt' || 'rtf' => (Icons.article_rounded, const Color(0xFF2B579A)),
    'xlsx' || 'xlsm' || 'ods' || 'csv' || 'tsv' => (Icons.table_chart_rounded, const Color(0xFF217346)),
    'pptx' || 'pptm' || 'odp' => (Icons.slideshow_rounded, const Color(0xFFD24726)),
    'epub' => (Icons.menu_book_rounded, const Color(0xFF7A5AA6)),
    'zip' => (Icons.folder_zip_rounded, const Color(0xFF8A6D3B)),
    _ => (Icons.description_rounded, Palette.accent),
  };
}

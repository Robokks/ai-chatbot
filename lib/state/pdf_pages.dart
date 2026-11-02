import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

/// Renders the first [maxPages] pages of [pdf] as JPEGs (150 dpi, longest
/// side at most 1568 px) with PDFium. Returns the pages and the page count.
Future<(List<Uint8List>, int)> defaultPdfRenderer(Uint8List pdf, int maxPages) async {
  if (kIsWeb) return (const <Uint8List>[], 0);
  await pdfrx.pdfrxFlutterInitialize();
  final doc = await pdfrx.PdfDocument.openData(pdf);
  try {
    final out = <Uint8List>[];
    for (final page in doc.pages.take(maxPages)) {
      final image = await page.render(
        fullWidth: page.width * 150 / 72,
        fullHeight: page.height * 150 / 72,
        width: (page.width * 150 / 72).round(),
        height: (page.height * 150 / 72).round(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (image == null) continue;
      try {
        out.add(img.encodeJpg(image.createImageNF(pixelSizeThreshold: 1568), quality: 85));
      } finally {
        image.dispose();
      }
    }
    return (out, doc.pages.length);
  } finally {
    await doc.dispose();
  }
}

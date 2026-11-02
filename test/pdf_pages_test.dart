import 'dart:io';
import 'dart:typed_data';

import 'package:ai_chatbot/state/pdf_pages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart' show Rect;
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart' show Pdfrx;
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// A PDF with [pages] pages of text.
Uint8List makePdf(int pages) {
  final doc = PdfDocument();
  for (var i = 0; i < pages; i++) {
    doc.pages.add().graphics.drawString('Page ${i + 1}: TOTAL 42.50',
        PdfStandardFont(PdfFontFamily.helvetica, 30), bounds: const Rect.fromLTWH(20, 20, 500, 60));
  }
  final bytes = Uint8List.fromList(doc.saveSync());
  doc.dispose();
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // No path_provider or bundled PDFium in plain test runs: the test runs
  // only when PDFIUM_PATH points at a libpdfium.
  final pdfium = Platform.environment['PDFIUM_PATH'];
  Pdfrx.cacheDirectoryPath = Directory.systemTemp.createTempSync('pdfrx').path;
  if (pdfium != null) Pdfrx.pdfiumModulePath = pdfium;
  test('scanned-PDF pages render as pictures, capped', () async {
    final (pages, total) = await defaultPdfRenderer(makePdf(3), 2);
    expect(total, 3);
    expect(pages, hasLength(2));
    final first = img.decodeJpg(pages.first)!;
    expect(first.width, greaterThan(800)); // 150 dpi of an A4-ish page
    expect(first.height, lessThanOrEqualTo(1568));
    // Mostly white with some dark text.
    final dark = first.data!.where((p) => p.luminance < 100).length;
    expect(dark, greaterThan(100));
  }, skip: pdfium == null ? 'Set PDFIUM_PATH to a libpdfium to run' : false);
}

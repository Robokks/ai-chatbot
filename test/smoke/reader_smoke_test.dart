// Real-model check, run by .github/workflows/reader-smoke.yml with
// READER_MODEL and READER_PROJECTOR pointing at LFM2-VL files. Skipped
// otherwise.
import 'dart:io';

import 'package:ai_chatbot/data/local/picture_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  final model = Platform.environment['READER_MODEL'];
  final projector = Platform.environment['READER_PROJECTOR'];
  test('LFM2-VL reads the text on a picture', () async {
    // A white "receipt" with big black text.
    final picture = img.Image(width: 480, height: 200)..clear(img.ColorRgb8(255, 255, 255));
    img.drawString(picture, 'CAFE ROMA', font: img.arial48, x: 30, y: 20, color: img.ColorRgb8(0, 0, 0));
    img.drawString(picture, 'TOTAL 42.50', font: img.arial48, x: 30, y: 110, color: img.ColorRgb8(0, 0, 0));
    final watch = Stopwatch()..start();
    final text = await LocalPictureReader().read(model!, projector!, img.encodePng(picture));
    // ignore: avoid_print
    print('Read in ${watch.elapsed}:\n$text');
    expect(text.toUpperCase(), contains('42.50'));
    expect(text.toUpperCase(), contains('ROMA'));
  }, skip: model == null ? 'Set READER_MODEL and READER_PROJECTOR to run' : false,
      timeout: const Timeout(Duration(minutes: 20)));
}

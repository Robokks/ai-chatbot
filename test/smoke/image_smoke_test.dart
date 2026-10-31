// Real-model check, run by .github/workflows/image-smoke.yml with
// SDXS_PATH set to a downloaded SDXS file. Skipped otherwise.
import 'dart:io';

import 'package:ai_chatbot/data/local/image_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final path = Platform.environment['SDXS_PATH'];
  test('SDXS makes a real 512×512 picture', () async {
    final engine = ImageEngineHost();
    expect(await engine.unsupportedReason(), isNull);
    final statuses = <String>[];
    final watch = Stopwatch()..start();
    final image = await engine.generate(path!, 'a red fox in autumn leaves, watercolor',
        seed: 42, onProgress: (s, _) => statuses.add(s));
    // ignore: avoid_print
    print('Made ${image.width}x${image.height} in ${watch.elapsed} (generation ${image.elapsed}); '
        'steps: ${statuses.toSet().join(' → ')}');
    expect(image.width, 512);
    expect(image.height, 512);
    expect(image.png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    final out = File('build/smoke/fox.png')..createSync(recursive: true);
    out.writeAsBytesSync(image.png);
    await engine.unload();
  }, skip: path == null ? 'Set SDXS_PATH to run' : false, timeout: const Timeout(Duration(minutes: 20)));
}

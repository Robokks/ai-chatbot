import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:llamadart/llamadart.dart';

import '../llm/local_provider.dart';

/// What the picture reader is asked to do with each picture.
const pictureReadInstructions =
    'You help an AI that cannot see. Look at this picture carefully.\n'
    '1. If there is any text (signs, documents, receipts, screenshots, handwriting), copy it '
    'out exactly, keeping the lines. Write tables as markdown tables.\n'
    '2. Then describe the picture: what it shows, people, objects, colors, charts and numbers, '
    'and anything unusual.\n'
    'Do not guess what is not visible. Answer in the same language as the text in the picture, '
    'or in English if there is none.';

/// Runs a vision model on one picture and returns its answer.
typedef VisionRunner = Future<String> Function(
    String modelPath, String projectorPath, Uint8List image, String instructions);

/// Reads pictures on this device with a vision model (LFM2-VL) through the
/// shared llama.cpp engine.
class LocalPictureReader {
  LocalPictureReader({LocalEngineHost? host, this._run})
      : host = host ?? LocalEngineHost.instance;

  final LocalEngineHost host;
  final VisionRunner? _run;

  /// Reads [image] (JPEG/PNG bytes), scaled down so its longest side is at
  /// most [maxSide] pixels.
  Future<String> read(String modelPath, String projectorPath, Uint8List image,
      {int maxSide = 768, String instructions = pictureReadInstructions}) async {
    final small = downscale(image, maxSide);
    final run = _run;
    if (run != null) return run(modelPath, projectorPath, small, instructions);
    final release = await host.acquire();
    try {
      final engine = await host.engineFor(modelPath, projector: projectorPath);
      if (!(await engine.capabilities).supportsVision) {
        throw const PictureReadException('The picture reader model could not load its vision part.');
      }
      final text = await engine.create(
        [
          LlamaChatMessage.withContent(role: LlamaChatRole.user, content: [
            LlamaImageContent(bytes: small),
            LlamaTextContent(instructions),
          ]),
        ],
        params: const GenerationParams(maxTokens: 1024, temp: 0.1, minP: 0.15, penalty: 1.05),
      ).text();
      return text.trim();
    } finally {
      release();
    }
  }
}

class PictureReadException implements Exception {
  const PictureReadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Re-encodes [bytes] as JPEG with the longest side at most [maxSide].
/// Returns the input when it is already small or can't be decoded.
Uint8List downscale(Uint8List bytes, int maxSide) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longest <= maxSide) return bytes;
  final out = decoded.width >= decoded.height
      ? img.copyResize(decoded, width: maxSide)
      : img.copyResize(decoded, height: maxSide);
  return img.encodeJpg(out, quality: 88);
}

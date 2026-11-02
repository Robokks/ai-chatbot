import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../local/image_engine.dart';

/// Free online picture makers (FLUX.1-schnell) on Cloudflare Workers AI and
/// Hugging Face.
class CloudImageClient {
  CloudImageClient({http.Client Function()? client}) : _newClient = client ?? http.Client.new;

  final http.Client Function() _newClient;

  static const cloudflareModel = '@cf/black-forest-labs/flux-1-schnell';
  static const huggingFaceModel = 'black-forest-labs/FLUX.1-schnell';

  /// [chatBaseUrl] is the Cloudflare provider's base URL
  /// (`…/accounts/<id>/ai/v1`).
  Future<MadeImage> cloudflare(String chatBaseUrl, String key, String prompt,
      {int? seed, ImageJob? job}) async {
    final base = chatBaseUrl.replaceFirst(RegExp(r'/ai/v1/?$'), '/ai/run/');
    final j = await _post('Cloudflare', Uri.parse('$base$cloudflareModel'), key,
        {'prompt': prompt, 'steps': 4, 'seed': ?seed}, job, json: true);
    final image = (((j as Map)['result'] as Map?)?['image']) as String?;
    if (image == null) throw const ImageMakerException('Cloudflare sent no picture back.');
    return _made(base64Decode(image), seed);
  }

  Future<MadeImage> huggingFace(String key, String prompt, {int? seed, ImageJob? job}) async {
    final bytes = await _post(
        'Hugging Face',
        Uri.parse('https://router.huggingface.co/hf-inference/models/$huggingFaceModel'),
        key,
        {
          'inputs': prompt,
          if (seed != null) 'parameters': {'seed': seed},
        },
        job,
        json: false);
    return _made(bytes as Uint8List, seed);
  }

  Future<Object> _post(String name, Uri url, String key, Map<String, Object?> body, ImageJob? job,
      {required bool json}) async {
    final c = _newClient();
    final watch = Stopwatch()..start();
    final cancelled = Completer<Never>();
    job?.onCancel(() {
      c.close();
      if (!cancelled.isCompleted) cancelled.completeError(const ImageMakerException('Stopped.'));
    });
    try {
      final res = await Future.any([
        c
            .post(url,
                headers: {
                  'Authorization': 'Bearer $key',
                  'Content-Type': 'application/json',
                  if (!json) 'Accept': 'image/png',
                },
                body: jsonEncode(body))
            .timeout(const Duration(minutes: 3)),
        cancelled.future,
      ]);
      _lastElapsed = watch.elapsed;
      if (res.statusCode != 200) throw ImageMakerException(_error(name, res.statusCode, res.body));
      return json ? jsonDecode(res.body) as Object : res.bodyBytes;
    } on ImageMakerException {
      rethrow;
    } on TimeoutException {
      throw ImageMakerException('$name took too long to answer. Try again.');
    } catch (e) {
      if (job?.cancelled ?? false) throw const ImageMakerException('Stopped.');
      throw ImageMakerException('Could not reach $name ($e).');
    } finally {
      c.close();
    }
  }

  Duration _lastElapsed = Duration.zero;

  static String _error(String name, int status, String body) => switch (status) {
        429 || 402 => '$name: the free picture limit is used up for now. Try another service '
            'or try again tomorrow.',
        401 || 403 => '$name did not accept the key. Check it in Settings → $name'
            '${name == 'Cloudflare' ? ' (the token needs the "Workers AI" permission)' : ''}.',
        503 => '$name is starting the picture model. Try again in a minute.',
        _ => '$name could not make the picture (error $status).',
      };

  /// Pictures are stored as PNG; the services send JPEG or PNG.
  MadeImage _made(Uint8List bytes, int? seed) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw const ImageMakerException('The picture could not be opened.');
    final png = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 ? bytes : img.encodePng(decoded);
    return MadeImage(
      png: png,
      width: decoded.width,
      height: decoded.height,
      seed: seed ?? 0,
      elapsed: _lastElapsed,
    );
  }
}

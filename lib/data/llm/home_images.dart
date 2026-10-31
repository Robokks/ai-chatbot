import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../local/image_engine.dart';

/// Makes pictures on a paired home server (`/v1/images/...`).
class HomeImageClient {
  HomeImageClient({http.Client Function()? client}) : _newClient = client ?? http.Client.new;

  final http.Client Function() _newClient;

  Map<String, String> _headers(String key) => {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      };

  /// Image model ids the host shares; empty when it shares none (or is an
  /// older version without the image maker).
  Future<List<String>> models(String baseUrl, String key) async {
    final c = _newClient();
    try {
      final res = await c
          .get(Uri.parse('$baseUrl/images/models'), headers: _headers(key))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      return [for (final m in j['data'] as List? ?? const []) (m as Map)['id'] as String];
    } catch (_) {
      return const [];
    } finally {
      c.close();
    }
  }

  /// Asks the host for one 512×512 picture. [job] can stop the wait.
  Future<MadeImage> generate(String baseUrl, String key, String prompt,
      {String? model, int? seed, ImageJob? job}) async {
    final c = _newClient();
    final watch = Stopwatch()..start();
    final cancelled = Completer<Never>();
    job?.onCancel(() {
      c.close();
      if (!cancelled.isCompleted) {
        cancelled.completeError(const ImageMakerException('Stopped.'));
      }
    });
    try {
      final res = await Future.any([
        c
            .post(
              Uri.parse('$baseUrl/images/generations'),
              headers: _headers(key),
              body: jsonEncode({
                'prompt': prompt,
                'model': ?model,
                'n': 1,
                'size': '512x512',
                'response_format': 'b64_json',
                'seed': ?seed,
              }),
            )
            .timeout(const Duration(minutes: 10)),
        cancelled.future,
      ]);
      final j = jsonDecode(res.body);
      if (res.statusCode != 200) {
        final msg = j is Map ? (j['error'] is Map ? j['error']['message'] : j['error']) : null;
        throw ImageMakerException('${msg ?? 'The home server could not make the picture '
            '(error ${res.statusCode}).'}');
      }
      final first = ((j as Map)['data'] as List).first as Map;
      return MadeImage(
        png: base64Decode(first['b64_json'] as String),
        width: 512,
        height: 512,
        seed: (first['seed'] as num?)?.toInt() ?? seed ?? 0,
        elapsed: watch.elapsed,
      );
    } on ImageMakerException {
      rethrow;
    } on TimeoutException {
      throw const ImageMakerException('The home server took too long to answer.');
    } catch (e) {
      if (job?.cancelled ?? false) throw const ImageMakerException('Stopped.');
      throw ImageMakerException('Could not reach the home server ($e).');
    } finally {
      c.close();
    }
  }
}

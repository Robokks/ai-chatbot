import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

import '../llm/local_provider.dart';

/// A picture made by the image maker.
class MadeImage {
  const MadeImage({
    required this.png,
    required this.width,
    required this.height,
    required this.seed,
    required this.elapsed,
  });

  final Uint8List png;
  final int width;
  final int height;
  final int seed;
  final Duration elapsed;
}

/// Lets the user stop a picture that is being made.
class ImageJob {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get cancelled => _cancelled;

  /// Runs [f] when the job is stopped (at once if it already was).
  void onCancel(void Function() f) {
    if (_cancelled) {
      f();
    } else {
      _listeners.add(f);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final f in List.of(_listeners)) {
      f();
    }
    _listeners.clear();
  }
}

/// The image maker failed; [message] is in plain words for the user.
class ImageMakerException implements Exception {
  const ImageMakerException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One loaded image model. The real one wraps llamadart's
/// [ImageGenerationEngine]; tests use a fake.
abstract class ImageBackend {
  /// Makes one picture. [onProgress] gets a short status and a 0..1 value
  /// (null when unknown).
  Future<MadeImage> generate(
    String prompt, {
    int? seed,
    required ImageJob job,
    void Function(String status, double? fraction)? onProgress,
  });

  Future<void> dispose();
}

typedef ImageBackendLoader = Future<ImageBackend> Function(String path);

/// Keeps one image model loaded and runs one picture at a time.
///
/// It shares the turn lock of [LocalEngineHost]: a picture waits for a chat
/// reply on this device to finish (and the other way round), and the chat
/// model is unloaded first so both never sit in memory together.
class ImageEngineHost {
  ImageEngineHost({
    LocalEngineHost? chat,
    ImageBackendLoader? loader,
    Future<String?> Function()? checkSupport,
  })  : chat = chat ?? LocalEngineHost.instance,
        _loader = loader ?? _loadLlamadart,
        _checkSupport = checkSupport ?? _llamadartSupport {
    this.chat.addOtherModel(unload);
  }

  static final instance = ImageEngineHost();

  final LocalEngineHost chat;
  final ImageBackendLoader _loader;
  final Future<String?> Function() _checkSupport;

  ImageBackend? _backend;
  String? _path;
  Future<String?>? _support;

  /// Whether a picture is being made right now.
  bool get busy => _busy;
  bool _busy = false;

  /// Null when this device can run the image maker, else why not (in plain
  /// words). Checked once.
  Future<String?> unsupportedReason() => _support ??= _checkSupport();

  bool isLoaded(String path) => _backend != null && _path == path;

  /// Makes one picture with the model file at [path].
  Future<MadeImage> generate(
    String path,
    String prompt, {
    int? seed,
    ImageJob? job,
    void Function(String status, double? fraction)? onProgress,
  }) async {
    job ??= ImageJob();
    final text = prompt.trim();
    if (text.isEmpty) throw const ImageMakerException('Describe the picture first.');
    final reason = await unsupportedReason();
    if (reason != null) throw ImageMakerException(reason);

    onProgress?.call('Waiting for the AI to be free…', null);
    final release = await chat.acquire();
    _busy = true;
    try {
      if (job.cancelled) throw const ImageMakerException('Stopped.');
      if (!isLoaded(path)) {
        onProgress?.call('Loading the image model…', null);
        await chat.unload();
        await unload();
        try {
          _backend = await _loader(path);
          _path = path;
        } catch (e) {
          throw ImageMakerException(friendlyImageError(e));
        }
      }
      if (job.cancelled) throw const ImageMakerException('Stopped.');
      try {
        return await _backend!.generate(text, seed: seed, job: job, onProgress: onProgress);
      } on ImageMakerException {
        rethrow;
      } catch (e) {
        if (job.cancelled) throw const ImageMakerException('Stopped.');
        throw ImageMakerException(friendlyImageError(e));
      }
    } finally {
      _busy = false;
      release();
    }
  }

  Future<void> unload() async {
    final b = _backend;
    _backend = null;
    _path = null;
    await b?.dispose();
  }

  /// Unloads [path] if it is the loaded model (before deleting the file).
  Future<void> release(String path) async {
    if (_path == path) await unload();
  }
}

/// Turns a runtime error into words the user understands.
String friendlyImageError(Object e) {
  final text = e.toString();
  final lower = text.toLowerCase();
  if (lower.contains('memory')) {
    return 'Not enough free memory to make a picture. Close other apps and try again.';
  }
  if (e is LlamaUnsupportedException) {
    return 'This device can\'t run the image maker ($text).';
  }
  if (lower.contains('cancel')) return 'Stopped.';
  return 'The image maker failed: $text';
}

Future<String?> _llamadartSupport() async {
  try {
    final c = await ImageGenerationEngine.checkRuntime();
    if (c.isSupported) return null;
    return 'This device can\'t run the image maker'
        '${c.unsupportedReason == null ? '' : ' (${c.unsupportedReason})'}.';
  } catch (e) {
    return 'This device can\'t run the image maker ($e).';
  }
}

Future<ImageBackend> _loadLlamadart(String path) async {
  final engine = await ImageGenerationEngine.load(ImageGenerationModel(ModelSource.path(path)));
  return _LlamadartImageBackend(engine);
}

class _LlamadartImageBackend implements ImageBackend {
  _LlamadartImageBackend(this.engine);
  final ImageGenerationEngine engine;

  @override
  Future<MadeImage> generate(
    String prompt, {
    int? seed,
    required ImageJob job,
    void Function(String status, double? fraction)? onProgress,
  }) async {
    // SDXS settings: one step, no guidance; raising them makes it worse.
    final task = await engine.generate(ImageGenerationRequest(
      prompt: prompt,
      width: 512,
      height: 512,
      steps: 1,
      guidanceScale: 1,
      seed: seed,
    ));
    job.onCancel(task.cancel);
    final sub = task.events.listen((e) {
      if (e is! ImageGenerationProgressEvent) return;
      final (label, base, span) = switch (e.phase) {
        ImageGenerationPhase.loading => ('Loading the image model…', 0.0, 0.1),
        ImageGenerationPhase.encodingPrompt => ('Reading your words…', 0.1, 0.1),
        ImageGenerationPhase.sampling => ('Drawing…', 0.2, 0.6),
        ImageGenerationPhase.decoding => ('Finishing the picture…', 0.8, 0.2),
      };
      final inPhase = e.steps > 0 ? (e.step / e.steps).clamp(0.0, 1.0) : 0.0;
      onProgress?.call(label, base + span * inPhase);
    });
    try {
      final result = await task.result;
      final image = result.images.first;
      return MadeImage(
        png: image.toPng(),
        width: image.width,
        height: image.height,
        seed: result.seed,
        elapsed: result.elapsed,
      );
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> dispose() => engine.dispose();
}

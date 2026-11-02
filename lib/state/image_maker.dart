import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/llm/cloud_images.dart';
import '../data/llm/home_images.dart';
import '../data/local/image_engine.dart';
import '../data/local/image_gallery.dart';
import '../data/local/local_models.dart';
import '../data/models.dart';
import 'app_state.dart';

/// Together's free FLUX model.
const togetherFluxModel = 'black-forest-labs/FLUX.1-schnell-Free';

/// Where a picture is made.
enum ImageTarget {
  cloudflare('Cloudflare FLUX', 'Free online · good quality'),
  huggingface('Hugging Face FLUX', 'Free online · good quality'),
  together('Together FLUX', 'Free online · good quality'),
  freellmapi('FreeLLMAPI', 'Free online through your PC'),
  homeServer('Home server', 'Your PC on this Wi-Fi'),
  thisDevice('This device', 'Offline · small model, simple pictures');

  const ImageTarget(this.label, this.note);
  final String label;
  final String note;
}

/// The image maker: makes pictures on this device, the paired home server
/// or a free online service, and keeps them in the [gallery].
class ImageMaker extends ChangeNotifier {
  ImageMaker(
    this.app, {
    ImageEngineHost? engine,
    HomeImageClient? home,
    CloudImageClient? cloud,
    ImageGallery? gallery,
  })  : engine = engine ?? ImageEngineHost.instance,
        home = home ?? HomeImageClient(),
        cloud = cloud ?? CloudImageClient(),
        gallery = gallery ?? ImageGallery(app.storage);

  final AppState app;
  final ImageEngineHost engine;
  final HomeImageClient home;
  final CloudImageClient cloud;
  final ImageGallery gallery;

  /// Image models the paired home server shares.
  List<String> hostModels = const [];

  /// Null when this device can run the image maker, else why not.
  String? unsupported;
  bool _checked = false;

  static const _targetKey = 'images.target';

  bool get busy => _job != null;
  ImageJob? _job;
  String? status;
  double? fraction;

  LocalModelInfo? get localModel => app.localModels.installedImageModel;
  bool get canMakeHere => unsupported == null && localModel != null;
  bool get hostOffers => hostModels.isNotEmpty && app.connectedHostName != null;

  String get hostName => app.connectedHostName ?? 'Home server';

  bool _ready(ImageTarget t) => switch (t) {
        ImageTarget.cloudflare => app.hasKey(ProviderKind.cloudflare),
        ImageTarget.huggingface => app.hasKey(ProviderKind.huggingface),
        ImageTarget.together => app.hasKey(ProviderKind.together),
        ImageTarget.freellmapi => app.hasKey(ProviderKind.freellmapi),
        ImageTarget.homeServer => hostOffers,
        ImageTarget.thisDevice => canMakeHere,
      };

  /// Places a picture can be made right now, best first.
  List<ImageTarget> get targets => [for (final t in ImageTarget.values) if (_ready(t)) t];

  /// Whether a picture can be made right now somewhere.
  bool get available => targets.isNotEmpty;

  /// The user's choice when it is available, else the best available place.
  /// "This device" is the answer when nothing is ready (it shows the
  /// download).
  ImageTarget get target {
    final saved = ImageTarget.values.asNameMap()[app.storage.getSetting(_targetKey)];
    if (saved != null && _ready(saved)) return saved;
    return targets.firstOrNull ?? ImageTarget.thisDevice;
  }

  String labelOf(ImageTarget t) => t == ImageTarget.homeServer ? hostName : t.label;

  /// Checks this device and the home server once (or again with [force]).
  Future<void> refresh({bool force = false}) async {
    if (!_checked || force) {
      _checked = true;
      unsupported = await engine.unsupportedReason();
    }
    final s = app.providers[ProviderKind.network];
    final key = app.keyFor(ProviderKind.network);
    hostModels = s == null || s.baseUrl.isEmpty || key.isEmpty || app.connectedHostName == null
        ? const []
        : await home.models(s.baseUrl, key);
    notifyListeners();
  }

  Future<void> setTarget(ImageTarget t) async {
    await app.storage.setSetting(_targetKey, t.name);
    notifyListeners();
  }

  void _progress(String s, double? f) {
    status = s;
    fraction = f;
    notifyListeners();
  }

  /// Makes one picture and adds it to the gallery.
  Future<GalleryImage> make(String prompt, {ImageTarget? where, int? seed}) async {
    if (_job != null) throw const ImageMakerException('A picture is already being made. Wait for it to finish.');
    if (prompt.trim().isEmpty) throw const ImageMakerException('Describe the picture first.');
    final at = where ?? target;
    final job = _job = ImageJob();
    _progress('Starting…', null);
    try {
      final MadeImage image;
      switch (at) {
        case ImageTarget.cloudflare:
          _progress('Making the picture on Cloudflare…', null);
          image = await cloud.cloudflare(app.providers[ProviderKind.cloudflare]!.baseUrl,
              app.keyFor(ProviderKind.cloudflare), prompt,
              seed: seed, job: job);
        case ImageTarget.huggingface:
          _progress('Making the picture on Hugging Face…', null);
          image = await cloud.huggingFace(app.keyFor(ProviderKind.huggingface), prompt, seed: seed, job: job);
        case ImageTarget.together:
          _progress('Making the picture on Together…', null);
          image = await home.generate(app.providers[ProviderKind.together]!.baseUrl,
              app.keyFor(ProviderKind.together), prompt,
              model: togetherFluxModel, seed: seed, job: job, size: null, service: 'Together');
        case ImageTarget.freellmapi:
          _progress('Making the picture through FreeLLMAPI…', null);
          image = await home.generate(app.providers[ProviderKind.freellmapi]!.baseUrl,
              app.keyFor(ProviderKind.freellmapi), prompt,
              seed: seed, job: job, size: null, service: 'FreeLLMAPI');
        case ImageTarget.homeServer:
          if (!hostOffers) throw const ImageMakerException('The home server does not share the image maker.');
          _progress('Making the picture on $hostName…', null);
          final s = app.providers[ProviderKind.network]!;
          image = await home.generate(s.baseUrl, app.keyFor(ProviderKind.network), prompt,
              model: hostModels.first, seed: seed, job: job);
        case ImageTarget.thisDevice:
          final m = localModel;
          if (m == null) {
            throw const ImageMakerException('Download the image model first (Create images → Download).');
          }
          image = await engine.generate(await app.localModels.pathFor(m.id), prompt,
              seed: seed, job: job, onProgress: _progress);
      }
      return await gallery.add(image.png,
          prompt: prompt.trim(),
          madeOn: labelOf(at),
          width: image.width,
          height: image.height,
          seed: image.seed);
    } finally {
      _job = null;
      status = null;
      fraction = null;
      notifyListeners();
    }
  }

  void stop() => _job?.cancel();
}

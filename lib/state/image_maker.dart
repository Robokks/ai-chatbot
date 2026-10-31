import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/llm/home_images.dart';
import '../data/local/image_engine.dart';
import '../data/local/image_gallery.dart';
import '../data/local/local_models.dart';
import '../data/models.dart';
import 'app_state.dart';

/// Where a picture is made.
enum ImageTarget { thisDevice, homeServer }

/// The image maker: makes pictures on this device or on the paired home
/// server and keeps them in the [gallery].
class ImageMaker extends ChangeNotifier {
  ImageMaker(
    this.app, {
    ImageEngineHost? engine,
    HomeImageClient? home,
    ImageGallery? gallery,
  })  : engine = engine ?? ImageEngineHost.instance,
        home = home ?? HomeImageClient(),
        gallery = gallery ?? ImageGallery(app.storage);

  final AppState app;
  final ImageEngineHost engine;
  final HomeImageClient home;
  final ImageGallery gallery;

  /// Image models the paired home server shares.
  List<String> hostModels = const [];

  /// Null when this device can run the image maker, else why not.
  String? unsupported;
  bool _checked = false;

  ImageTarget target = ImageTarget.thisDevice;

  bool get busy => _job != null;
  ImageJob? _job;
  String? status;
  double? fraction;

  LocalModelInfo? get localModel => app.localModels.installedImageModel;
  bool get canMakeHere => unsupported == null && localModel != null;
  bool get hostOffers => hostModels.isNotEmpty && app.connectedHostName != null;

  /// Whether a picture can be made right now somewhere.
  bool get available => canMakeHere || hostOffers;

  String get hostName => app.connectedHostName ?? 'Home server';

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
    if (target == ImageTarget.homeServer && !hostOffers) target = ImageTarget.thisDevice;
    if (target == ImageTarget.thisDevice && !canMakeHere && hostOffers) {
      target = ImageTarget.homeServer;
    }
    notifyListeners();
  }

  void setTarget(ImageTarget t) {
    target = t;
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
      final String madeOn;
      if (at == ImageTarget.homeServer) {
        if (!hostOffers) throw const ImageMakerException('The home server does not share the image maker.');
        _progress('Making the picture on $hostName…', null);
        final s = app.providers[ProviderKind.network]!;
        image = await home.generate(s.baseUrl, app.keyFor(ProviderKind.network), prompt,
            model: hostModels.first, seed: seed, job: job);
        madeOn = hostName;
      } else {
        final m = localModel;
        if (m == null) {
          throw const ImageMakerException('Download the image model first (Create images → Download).');
        }
        image = await engine.generate(await app.localModels.pathFor(m.id), prompt,
            seed: seed, job: job, onProgress: _progress);
        madeOn = 'This device';
      }
      return await gallery.add(image.png,
          prompt: prompt.trim(),
          madeOn: madeOn,
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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/storage.dart';
import '../models.dart';

/// A picture in the gallery.
class GalleryImage {
  GalleryImage({
    required this.id,
    required this.prompt,
    required this.createdAt,
    required this.madeOn,
    required this.width,
    required this.height,
    this.seed,
  });

  final String id;
  final String prompt;
  final DateTime createdAt;

  /// Where it was made: "This device" or the home server's name.
  final String madeOn;
  final int width;
  final int height;
  final int? seed;

  String get fileName => 'ai-image-$id.png';

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'createdAt': createdAt.toIso8601String(),
        'madeOn': madeOn,
        'width': width,
        'height': height,
        if (seed != null) 'seed': seed,
      };

  factory GalleryImage.fromJson(Map<String, dynamic> j) => GalleryImage(
        id: j['id'] as String,
        prompt: j['prompt'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        madeOn: j['madeOn'] as String? ?? '',
        width: j['width'] as int? ?? 512,
        height: j['height'] as int? ?? 512,
        seed: j['seed'] as int?,
      );
}

final _validId = RegExp(r'^[A-Za-z0-9_-]+$');

/// Pictures made by the image maker: PNG files in the app's folder and a
/// list (newest first) in settings.
class ImageGallery extends ChangeNotifier {
  ImageGallery(this._storage, {Directory? dir}) : _fixedDir = dir;

  final Storage? _storage;
  final Directory? _fixedDir;
  Directory? _dir;

  final List<GalleryImage> images = [];

  static const _key = 'images.gallery';

  Future<Directory> _folder() async {
    final d = _dir ??= _fixedDir ??
        Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}images');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _file(String id) async {
    if (!_validId.hasMatch(id)) throw ArgumentError.value(id, 'id', 'unsafe image id');
    return File('${(await _folder()).path}${Platform.pathSeparator}$id.png');
  }

  void load() {
    final raw = _storage?.getSetting(_key);
    images.clear();
    if (raw != null) {
      try {
        images.addAll((jsonDecode(raw) as List)
            .map((e) => GalleryImage.fromJson(Map<String, dynamic>.from(e))));
      } catch (_) {
        // A damaged list starts over; the files stay on disk.
      }
    }
    notifyListeners();
  }

  Future<void> _save() async =>
      _storage?.setSetting(_key, jsonEncode([for (final i in images) i.toJson()]));

  Future<GalleryImage> add(Uint8List png,
      {required String prompt, required String madeOn, int width = 512, int height = 512, int? seed}) async {
    final image = GalleryImage(
      id: newId(),
      prompt: prompt,
      createdAt: DateTime.now(),
      madeOn: madeOn,
      width: width,
      height: height,
      seed: seed,
    );
    await (await _file(image.id)).writeAsBytes(png, flush: true);
    images.insert(0, image);
    await _save();
    notifyListeners();
    return image;
  }

  /// The PNG bytes, or null when the file is gone.
  Future<Uint8List?> bytes(String id) async {
    final f = await _file(id);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> delete(String id) async {
    final f = await _file(id);
    if (await f.exists()) await f.delete();
    images.removeWhere((i) => i.id == id);
    await _save();
    notifyListeners();
  }

  /// Bytes used by all pictures.
  Future<int> bytesOnDisk() async {
    var total = 0;
    await for (final f in (await _folder()).list()) {
      if (f is File) total += await f.length();
    }
    return total;
  }
}

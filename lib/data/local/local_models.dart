import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/storage.dart';
import 'model_downloader.dart';

export 'model_downloader.dart' show DownloadCancelled, DownloadInterrupted;

/// What a local model does.
enum LocalModelKind {
  /// Chat (llama.cpp).
  chat,

  /// Makes pictures from text (stable-diffusion.cpp).
  image,

  /// Reads pictures (a vision model plus its projector) for models that
  /// can't see.
  vision,
}

/// A GGUF model that can run on the device.
class LocalModelInfo {
  const LocalModelInfo({
    required this.id,
    required this.name,
    required this.url,
    required this.sizeMb,
    required this.ramGb,
    this.note = '',
    this.sha256,
    this.kind = LocalModelKind.chat,
    this.license,
    this.projectorUrl,
    this.projectorSha256,
  });

  final LocalModelKind kind;

  /// Vision models: the multimodal projector (mmproj) file.
  final String? projectorUrl;
  final String? projectorSha256;

  bool get isVision => kind == LocalModelKind.vision;

  /// Name and link of the model's license, shown on its card.
  final ({String name, String url})? license;

  bool get isImage => kind == LocalModelKind.image;

  /// File stem, also used as the model id in the picker.
  final String id;
  final String name;
  final String url;
  final int sizeMb;
  final double ramGb;
  final String note;

  /// Expected SHA-256 of the file; downloads that don't match are deleted.
  final String? sha256;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'sizeMb': sizeMb,
        'ramGb': ramGb,
        'note': note,
        if (sha256 != null) 'sha256': sha256,
        if (kind != LocalModelKind.chat) 'kind': kind.name,
        if (projectorUrl != null) 'projectorUrl': projectorUrl,
        if (projectorSha256 != null) 'projectorSha256': projectorSha256,
      };

  factory LocalModelInfo.fromJson(Map<String, dynamic> j) => LocalModelInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String,
        sizeMb: j['sizeMb'] as int,
        ramGb: (j['ramGb'] as num).toDouble(),
        note: j['note'] as String? ?? '',
        sha256: j['sha256'] as String?,
        kind: LocalModelKind.values.asNameMap()[j['kind']] ?? LocalModelKind.chat,
        projectorUrl: j['projectorUrl'] as String?,
        projectorSha256: j['projectorSha256'] as String?,
      );

  /// Builds an entry from a pasted link: `hf://owner/repo/file.gguf` or an
  /// https URL ending in `.gguf`.
  static LocalModelInfo fromLink(String link) {
    var url = link.trim();
    if (url.startsWith('hf://')) {
      final parts = url.substring(5).split('/');
      if (parts.length < 3) throw const FormatException('Use hf://owner/repo/file.gguf');
      url = 'https://huggingface.co/${parts[0]}/${parts[1]}/resolve/main/'
          '${parts.sublist(2).join('/')}';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.path.toLowerCase().endsWith('.gguf')) {
      throw const FormatException('Paste a link to a .gguf file');
    }
    final id = safeModelId(Uri.decodeComponent(uri.pathSegments.last));
    return LocalModelInfo(id: id, name: id, url: url, sizeMb: 0, ramGb: 0, note: 'Custom');
  }
}

/// Turns a file name into a model id that is safe to use as a file name in
/// the models folder: no directories, no `..`, only `[A-Za-z0-9._-]`.
String safeModelId(String fileName) {
  var name = fileName.split(RegExp(r'[/\\]')).last;
  if (name.toLowerCase().endsWith('.gguf')) name = name.substring(0, name.length - 5);
  name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').replaceFirst(RegExp(r'^\.+'), '');
  if (name.isEmpty) throw const FormatException('Invalid model file name');
  return name.length > 120 ? name.substring(0, 120) : name;
}

final _validId = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

String _hf(String repo, String file) => 'https://huggingface.co/$repo/resolve/main/$file';

/// A file at a fixed revision, so the download never changes under us.
String _hfAt(String repo, String revision, String file) =>
    'https://huggingface.co/$repo/resolve/$revision/$file';

/// Built-in suggestions. Liquid AI's LFM models are built for phones.
final builtInLocalModels = <LocalModelInfo>[
  LocalModelInfo(
    id: 'LFM2-350M-Q4_K_M',
    name: 'LFM2 350M',
    url: _hf('LiquidAI/LFM2-350M-GGUF', 'LFM2-350M-Q4_K_M.gguf'),
    sizeMb: 219,
    ramGb: 1,
    note: 'Tiny and very fast. Good for quick, simple tasks.',
    sha256: 'a4d000c7064bd3b2e42c6845836286a899a4e79cf1791da1a6797b58d575957d',
  ),
  LocalModelInfo(
    id: 'LFM2-700M-Q4_K_M',
    name: 'LFM2 700M',
    url: _hf('LiquidAI/LFM2-700M-GGUF', 'LFM2-700M-Q4_K_M.gguf'),
    sizeMb: 447,
    ramGb: 1.5,
    note: 'Fast on most phones.',
    sha256: '684e8406dc13321452b3f6aeca432776e2a6a7e1ad6c23f7887b8fe3efbe2efa',
  ),
  LocalModelInfo(
    id: 'LFM2-1.2B-Q4_K_M',
    name: 'LFM2 1.2B',
    url: _hf('LiquidAI/LFM2-1.2B-GGUF', 'LFM2-1.2B-Q4_K_M.gguf'),
    sizeMb: 697,
    ramGb: 2,
    note: 'Recommended. Best balance of speed and quality.',
    sha256: '55175400e3f509a9616227afeffd58d87e80b9f628a5d3d54ada884d85221fed',
  ),
  LocalModelInfo(
    id: 'LFM2-2.6B-Q4_K_M',
    name: 'LFM2 2.6B',
    url: _hf('LiquidAI/LFM2-2.6B-GGUF', 'LFM2-2.6B-Q4_K_M.gguf'),
    sizeMb: 1491,
    ramGb: 4,
    note: 'Smartest LFM2. Needs a recent phone or a PC.',
    sha256: '384bc877b6c37064982f96885bef69e4475919f5969218ed4e3b9399ae0340df',
  ),
  LocalModelInfo(
    id: 'gemma-3-1b-it-Q4_K_M',
    name: 'Gemma 3 1B',
    url: _hf('unsloth/gemma-3-1b-it-GGUF', 'gemma-3-1b-it-Q4_K_M.gguf'),
    sizeMb: 769,
    ramGb: 2,
    note: 'Google\'s small model.',
    sha256: '8270790f3ab69fdfe860b7b64008d9a19986d8df7e407bb018184caa08798ebd',
  ),
  LocalModelInfo(
    id: 'qwen2.5-1.5b-instruct-q4_k_m',
    name: 'Qwen 2.5 1.5B',
    url: _hf('Qwen/Qwen2.5-1.5B-Instruct-GGUF', 'qwen2.5-1.5b-instruct-q4_k_m.gguf'),
    sizeMb: 1066,
    ramGb: 2.5,
    note: 'Good at code and many languages.',
    sha256: '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
  ),
  ...builtInImageModels,
  ...builtInVisionModels,
];

/// Picture readers: Liquid AI's LFM2-VL describes pictures and reads the
/// text in them, for chat models that can't see.
final builtInVisionModels = <LocalModelInfo>[
  LocalModelInfo(
    id: 'LFM2-VL-450M-Q8_0',
    name: 'LFM2-VL 450M (picture reader)',
    url: _hf('LiquidAI/LFM2-VL-450M-GGUF', 'LFM2-VL-450M-Q8_0.gguf'),
    projectorUrl: _hf('LiquidAI/LFM2-VL-450M-GGUF', 'mmproj-LFM2-VL-450M-Q8_0.gguf'),
    sizeMb: 480,
    ramGb: 1.5,
    note: 'Small and fast. Reads text in photos and describes them, so on-device models, '
        'DeepSeek and Groq can understand your pictures.',
    kind: LocalModelKind.vision,
    license: (name: 'LFM Open License v1.0', url: 'https://huggingface.co/LiquidAI/LFM2-VL-450M'),
  ),
  LocalModelInfo(
    id: 'LFM2-VL-1.6B-Q8_0',
    name: 'LFM2-VL 1.6B (picture reader)',
    url: _hf('LiquidAI/LFM2-VL-1.6B-GGUF', 'LFM2-VL-1.6B-Q8_0.gguf'),
    projectorUrl: _hf('LiquidAI/LFM2-VL-1.6B-GGUF', 'mmproj-LFM2-VL-1.6B-Q8_0.gguf'),
    sizeMb: 1700,
    ramGb: 3,
    note: 'Better with small text, tables and handwriting. Best on a PC or a recent phone.',
    kind: LocalModelKind.vision,
    license: (name: 'LFM Open License v1.0', url: 'https://huggingface.co/LiquidAI/LFM2-VL-1.6B'),
  ),
];

/// Image models. SDXS makes a 512×512 picture in one step and is the
/// smallest model llamadart validates on phones.
final builtInImageModels = <LocalModelInfo>[
  LocalModelInfo(
    id: 'sdxs-512-tinySDdistilled_Q8_0',
    name: 'SDXS 512',
    url: _hfAt('concedo/sdxs-512-tinySDdistilled-GGUF', '3144d898d61492f8382ffcabec055733fc5b2a0e',
        'sdxs-512-tinySDdistilled_Q8_0.gguf'),
    sizeMb: 651,
    ramGb: 2,
    sha256: '409ab23582ee074c6b9d5395784fc0741b0599fb9d138686c69087c71678eb6a',
    note: 'Makes a 512×512 picture from your words in a few seconds on a PC, '
        'or under a minute on most phones.',
    kind: LocalModelKind.image,
    license: (
      name: 'CreativeML Open RAIL++-M',
      url: 'https://huggingface.co/concedo/sdxs-512-tinySDdistilled-GGUF',
    ),
  ),
];

class ChecksumMismatch implements Exception {
  @override
  String toString() => 'The downloaded file is damaged or not the expected model '
      '(checksum mismatch). It was deleted.';
}

/// Downloads, imports, lists and deletes GGUF files in the app's data folder.
class LocalModelStore extends ChangeNotifier {
  LocalModelStore(
    this._storage, {
    Directory? dir,
    http.Client? client,
    ModelDownloader? downloader,
  })  : _fixedDir = dir,
        _downloader = downloader ?? defaultModelDownloader(client);

  final Storage? _storage;
  final ModelDownloader _downloader;
  final Directory? _fixedDir;
  Directory? _dir;

  final List<LocalModelInfo> custom = [];
  final Set<String> installed = {};

  /// Download progress 0..1 by model id (missing = not downloading).
  final Map<String, double> progress = {};

  /// Short status for an active download, e.g. "Waiting for internet…".
  final Map<String, String> status = {};

  /// Downloads that stopped part-way and can be resumed.
  final Set<String> interrupted = {};

  List<LocalModelInfo> get all => [...builtInLocalModels, ...custom];

  List<LocalModelInfo> get chatModels => [
        for (final m in all)
          if (m.kind == LocalModelKind.chat) m,
      ];
  List<LocalModelInfo> get visionModels => [for (final m in all) if (m.isVision) m];

  /// The picture reader to use: the biggest downloaded one, or null.
  LocalModelInfo? get installedVisionModel {
    LocalModelInfo? best;
    for (final m in visionModels) {
      if (installed.contains(m.id) && (best == null || m.sizeMb > best.sizeMb)) best = m;
    }
    return best;
  }
  List<LocalModelInfo> get imageModels => [for (final m in all) if (m.isImage) m];

  /// The downloaded image model to use, or null.
  LocalModelInfo? get installedImageModel {
    for (final m in imageModels) {
      if (installed.contains(m.id)) return m;
    }
    return null;
  }

  LocalModelInfo? byId(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<Directory> _modelsDir() async {
    final d = _dir ??= _fixedDir ??
        Directory(
            '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}models');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String> pathFor(String id) async {
    if (!_validId.hasMatch(id)) throw ArgumentError.value(id, 'id', 'unsafe model id');
    return '${(await _modelsDir()).path}${Platform.pathSeparator}$id.gguf';
  }

  /// Where a vision model's projector is stored.
  Future<String> projectorPathFor(String id) async =>
      '${(await pathFor(id)).replaceFirst(RegExp(r'\.gguf$'), '')}.mmproj.gguf';

  Future<void> load() async {
    final raw = _storage?.getSetting('localModels.custom');
    if (raw != null) {
      custom
        ..clear()
        ..addAll((jsonDecode(raw) as List)
            .map((e) => LocalModelInfo.fromJson(Map<String, dynamic>.from(e))));
    }
    installed.clear();
    interrupted.clear();
    await for (final f in (await _modelsDir()).list()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      final partial = name.endsWith('.gguf.part');
      final stem = partial
          ? name.substring(0, name.length - 10)
          : name.endsWith('.gguf')
              ? name.substring(0, name.length - 5)
              : '';
      if (!_validId.hasMatch(stem) || stem.endsWith('.mmproj')) continue;
      (partial ? interrupted : installed).add(stem);
    }
    // A vision model needs its projector too.
    for (final m in all) {
      if (m.projectorUrl != null &&
          installed.contains(m.id) &&
          !await File(await projectorPathFor(m.id)).exists()) {
        installed.remove(m.id);
        interrupted.add(m.id);
      }
    }
    interrupted.removeAll(installed);
    notifyListeners();

    // Pick up downloads that kept running (or stopped) while the app was closed.
    try {
      await _downloader.init();
      final previous = await _downloader.previous();
      for (final e in previous.entries) {
        final m = byId(e.key.replaceFirst(RegExp(r'\.mmproj$'), ''));
        if (m == null || installed.contains(m.id)) continue;
        if (e.value) {
          unawaited(download(m).catchError((_) {}));
        } else {
          interrupted.add(m.id);
        }
      }
      notifyListeners();
    } catch (_) {
      // Background downloads unavailable (e.g. tests): plain downloads still work.
    }
  }

  Future<void> _saveCustom() async => _storage?.setSetting(
      'localModels.custom', jsonEncode(custom.map((m) => m.toJson()).toList()));

  Future<void> addCustom(LocalModelInfo m) async {
    if (byId(m.id) != null) return;
    custom.add(m);
    await _saveCustom();
    notifyListeners();
  }

  /// Downloads [m] (resuming a partial download when possible), checks its
  /// SHA-256 when pinned, and installs it as `<id>.gguf`.
  Future<void> download(LocalModelInfo m) async {
    if (progress.containsKey(m.id)) return;
    progress[m.id] = 0;
    interrupted.remove(m.id);
    notifyListeners();
    // A vision model is two files: its projector (first) and the model.
    final parts = <(String, String, String, String?)>[
      if (m.projectorUrl != null)
        ('${m.id}.mmproj', m.projectorUrl!, await projectorPathFor(m.id), m.projectorSha256),
      (m.id, m.url, await pathFor(m.id), m.sha256),
    ];
    String? current;
    try {
      for (var i = 0; i < parts.length; i++) {
        final (partId, url, path, sha) = parts[i];
        if (parts.length > 1 && await File(path).exists()) continue;
        current = partId;
        _activePart[m.id] = partId;
        final label = parts.length > 1 ? 'Part ${i + 1} of ${parts.length}: ' : '';
        final file = await _downloader.download(
          id: partId,
          url: url,
          partPath: '$path.part',
          displayName: m.name,
          onProgress: (p) {
            progress[m.id] = p;
            notifyListeners();
          },
          onStatus: (s) {
            s == null && label.isEmpty ? status.remove(m.id) : status[m.id] = '$label${s ?? 'downloading…'}';
            notifyListeners();
          },
        );
        status[m.id] = 'Checking file…';
        progress[m.id] = 1;
        notifyListeners();
        if (sha != null && await compute(sha256OfFile, file) != sha.toLowerCase()) {
          await File(file).delete();
          throw ChecksumMismatch();
        }
        await _move(file, path);
        progress[m.id] = 0;
      }
      installed.add(m.id);
    } on DownloadCancelled {
      if (current != null) {
        final part = parts.firstWhere((p) => p.$1 == current);
        await _downloader.discard(current, '${part.$3}.part');
      }
      rethrow;
    } on DownloadInterrupted {
      interrupted.add(m.id);
      rethrow;
    } finally {
      _activePart.remove(m.id);
      progress.remove(m.id);
      status.remove(m.id);
      notifyListeners();
    }
  }

  /// The download id of the file being fetched for each model.
  final Map<String, String> _activePart = {};

  static Future<void> _move(String from, String to) async {
    if (from == to) return;
    try {
      await File(from).rename(to);
    } on FileSystemException {
      await File(from).copy(to);
      await File(from).delete();
    }
  }

  Future<void> cancel(String id) => _downloader.cancel(_activePart[id] ?? id);

  /// Bytes used by downloaded and partial model files.
  Future<int> bytesOnDisk() async {
    var total = 0;
    await for (final f in (await _modelsDir()).list()) {
      if (f is File) total += await f.length();
    }
    return total;
  }

  /// Size of an installed model file, or null.
  Future<int?> installedBytes(String id) async {
    final f = File(await pathFor(id));
    return await f.exists() ? f.length() : null;
  }

  /// Throws away a stopped download's partial data.
  Future<void> discardPartial(String id) async {
    await _downloader.discard(id, '${await pathFor(id)}.part');
    await _downloader.discard('$id.mmproj', '${await projectorPathFor(id)}.part');
    interrupted.remove(id);
    notifyListeners();
  }
  /// Copies a `.gguf` file the user picked into the models folder.
  Future<LocalModelInfo> importFile(String sourcePath, String fileName) async {
    final id = safeModelId(fileName);
    final size = await File(sourcePath).length();
    final m = LocalModelInfo(
        id: id, name: id, url: '', sizeMb: size ~/ (1024 * 1024), ramGb: 0, note: 'Imported');
    progress[id] = 0;
    notifyListeners();
    try {
      await File(sourcePath).copy(await pathFor(id));
      installed.add(id);
      await addCustom(m);
    } finally {
      progress.remove(id);
      notifyListeners();
    }
    return m;
  }

  Future<void> delete(String id) async {
    for (final path in [await pathFor(id), await projectorPathFor(id)]) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
    installed.remove(id);
    notifyListeners();
  }

  Future<void> removeCustom(String id) async {
    await delete(id);
    custom.removeWhere((m) => m.id == id);
    await _saveCustom();
    notifyListeners();
  }
}


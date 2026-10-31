import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/storage.dart';

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
  });

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
      };

  factory LocalModelInfo.fromJson(Map<String, dynamic> j) => LocalModelInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String,
        sizeMb: j['sizeMb'] as int,
        ramGb: (j['ramGb'] as num).toDouble(),
        note: j['note'] as String? ?? '',
        sha256: j['sha256'] as String?,
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

/// Built-in suggestions. Liquid AI's LFM models are built for phones.
final builtInLocalModels = <LocalModelInfo>[
  LocalModelInfo(
    id: 'LFM2-350M-Q4_K_M',
    name: 'LFM2 350M',
    url: _hf('LiquidAI/LFM2-350M-GGUF', 'LFM2-350M-Q4_K_M.gguf'),
    sizeMb: 230,
    ramGb: 1,
    note: 'Tiny and very fast. Good for quick, simple tasks.',
  ),
  LocalModelInfo(
    id: 'LFM2-700M-Q4_K_M',
    name: 'LFM2 700M',
    url: _hf('LiquidAI/LFM2-700M-GGUF', 'LFM2-700M-Q4_K_M.gguf'),
    sizeMb: 470,
    ramGb: 1.5,
    note: 'Fast on most phones.',
  ),
  LocalModelInfo(
    id: 'LFM2-1.2B-Q4_K_M',
    name: 'LFM2 1.2B',
    url: _hf('LiquidAI/LFM2-1.2B-GGUF', 'LFM2-1.2B-Q4_K_M.gguf'),
    sizeMb: 730,
    ramGb: 2,
    note: 'Recommended. Best balance of speed and quality.',
  ),
  LocalModelInfo(
    id: 'LFM2-2.6B-Q4_K_M',
    name: 'LFM2 2.6B',
    url: _hf('LiquidAI/LFM2-2.6B-GGUF', 'LFM2-2.6B-Q4_K_M.gguf'),
    sizeMb: 1600,
    ramGb: 4,
    note: 'Smartest LFM2. Needs a recent phone or a PC.',
  ),
  LocalModelInfo(
    id: 'gemma-3-1b-it-Q4_K_M',
    name: 'Gemma 3 1B',
    url: _hf('unsloth/gemma-3-1b-it-GGUF', 'gemma-3-1b-it-Q4_K_M.gguf'),
    sizeMb: 810,
    ramGb: 2,
    note: 'Google\'s small model.',
  ),
  LocalModelInfo(
    id: 'qwen2.5-1.5b-instruct-q4_k_m',
    name: 'Qwen 2.5 1.5B',
    url: _hf('Qwen/Qwen2.5-1.5B-Instruct-GGUF', 'qwen2.5-1.5b-instruct-q4_k_m.gguf'),
    sizeMb: 1100,
    ramGb: 2.5,
    note: 'Good at code and many languages.',
  ),
];

class DownloadCancelled implements Exception {}

class ChecksumMismatch implements Exception {
  @override
  String toString() => 'The downloaded file is damaged or not the expected model '
      '(checksum mismatch). It was deleted.';
}

/// Downloads, imports, lists and deletes GGUF files in the app's data folder.
class LocalModelStore extends ChangeNotifier {
  LocalModelStore(this._storage, {Directory? dir, http.Client? client})
      : _fixedDir = dir,
        _client = client ?? http.Client();

  final Storage? _storage;
  final http.Client _client;
  final Directory? _fixedDir;
  Directory? _dir;

  final List<LocalModelInfo> custom = [];
  final Set<String> installed = {};

  /// Download progress 0..1 by model id (missing = not downloading).
  final Map<String, double> progress = {};
  final Set<String> _cancelled = {};

  List<LocalModelInfo> get all => [...builtInLocalModels, ...custom];

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

  Future<void> load() async {
    final raw = _storage?.getSetting('localModels.custom');
    if (raw != null) {
      custom
        ..clear()
        ..addAll((jsonDecode(raw) as List)
            .map((e) => LocalModelInfo.fromJson(Map<String, dynamic>.from(e))));
    }
    installed.clear();
    await for (final f in (await _modelsDir()).list()) {
      final name = f.uri.pathSegments.last;
      final id = name.endsWith('.gguf') ? name.substring(0, name.length - 5) : '';
      if (f is File && _validId.hasMatch(id)) {
        installed.add(id);
      }
    }
    notifyListeners();
  }

  Future<void> _saveCustom() async => _storage?.setSetting(
      'localModels.custom', jsonEncode(custom.map((m) => m.toJson()).toList()));

  Future<void> addCustom(LocalModelInfo m) async {
    if (byId(m.id) != null) return;
    custom.add(m);
    await _saveCustom();
    notifyListeners();
  }

  /// Downloads [m] to `<id>.gguf` via a `.part` file. Throws on failure.
  Future<void> download(LocalModelInfo m) async {
    if (progress.containsKey(m.id)) return;
    _cancelled.remove(m.id);
    progress[m.id] = 0;
    notifyListeners();
    final path = await pathFor(m.id);
    final part = File('$path.part');
    IOSink? sink;
    try {
      final res = await _client.send(http.Request('GET', Uri.parse(m.url)));
      if (res.statusCode != 200) {
        throw HttpException(res.statusCode == 401 || res.statusCode == 403
            ? 'This model needs a Hugging Face login (status ${res.statusCode}).'
            : 'Download failed (status ${res.statusCode}).');
      }
      final total = res.contentLength ?? m.sizeMb * 1024 * 1024;
      var received = 0;
      var lastNotify = DateTime.now();
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      sink = part.openWrite();
      await for (final chunk in res.stream) {
        if (_cancelled.contains(m.id)) throw DownloadCancelled();
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (DateTime.now().difference(lastNotify).inMilliseconds > 200) {
          progress[m.id] = total > 0 ? (received / total).clamp(0, 1) : 0;
          lastNotify = DateTime.now();
          notifyListeners();
        }
      }
      await sink.close();
      sink = null;
      hasher.close();
      final expected = m.sha256;
      if (expected != null && digest.value.toString() != expected.toLowerCase()) {
        throw ChecksumMismatch();
      }
      await part.rename(path);
      installed.add(m.id);
    } catch (_) {
      await sink?.close();
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      progress.remove(m.id);
      _cancelled.remove(m.id);
      notifyListeners();
    }
  }

  void cancel(String id) {
    if (progress.containsKey(id)) _cancelled.add(id);
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
    final f = File(await pathFor(id));
    if (await f.exists()) await f.delete();
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

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

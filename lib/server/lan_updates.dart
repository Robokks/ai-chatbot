import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// The Windows ZIP produced by our checked-in release workflow. Updates are
/// downloaded only; the app never extracts archives or launches an installer.
const windowsUpdateFilename = 'Chatbot-windows-x64.zip';
const maxWindowsUpdateBytes = 1024 * 1024 * 1024;

class LanUpdateManifest {
  const LanUpdateManifest({
    required this.release,
    required this.publishedAt,
    required this.bytes,
    required this.sha256Hex,
  });
  final String release;
  final DateTime publishedAt;
  final int bytes;
  final String sha256Hex;
  Map<String, dynamic> toJson() => {
    'release': release,
    'publishedAt': publishedAt.toUtc().toIso8601String(),
    'filename': windowsUpdateFilename,
    'bytes': bytes,
    'sha256': sha256Hex,
  };
  factory LanUpdateManifest.fromJson(Map<String, dynamic> value) {
    final bytes = value['bytes'];
    final digest = value['sha256'];
    final release = value['release'];
    if (value['filename'] != windowsUpdateFilename ||
        bytes is! int ||
        bytes <= 0 ||
        bytes > maxWindowsUpdateBytes ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        release is! String ||
        release.isEmpty ||
        release.length > 200) {
      throw const FormatException('Invalid Windows update manifest');
    }
    return LanUpdateManifest(
      release: release,
      publishedAt: DateTime.parse(value['publishedAt'] as String).toUtc(),
      bytes: bytes,
      sha256Hex: digest,
    );
  }
}

/// One bounded release cache on Main. A failed refresh retains the last verified
/// archive. The release API is deliberately tag/latest (our rolling prerelease).
class LanUpdateCache {
  LanUpdateCache({required this.directory, http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;
  final Directory directory;
  final http.Client _client;
  final bool _ownsClient;
  Future<LanUpdateManifest>? _refreshing;
  Future<void> _gate = Future<void>.value();
  final _snapshots = <LanUpdateSnapshot>{};
  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _gate;
    final done = Completer<void>();
    _gate = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  /// Opens metadata and a file handle together. Refresh waits until active
  /// downloads close, so Windows never replaces a ZIP that is still in use.
  Future<LanUpdateSnapshot> openSnapshot() => _locked(() async {
    final info = _manifest;
    if (info == null) {
      throw StateError('No Windows update is cached');
    }
    final handle = await archive.open();
    late LanUpdateSnapshot snapshot;
    snapshot = LanUpdateSnapshot._(
      info,
      handle,
      () => _snapshots.remove(snapshot),
    );
    _snapshots.add(snapshot);
    return snapshot;
  });
  LanUpdateManifest? _manifest;
  LanUpdateManifest? get manifest => _manifest;
  File get archive => File('${directory.path}/$windowsUpdateFilename');
  File get _manifestFile => File('${directory.path}/manifest.json');

  Future<void> load() async {
    _manifest = null;
    try {
      final info = LanUpdateManifest.fromJson(
        jsonDecode(await _manifestFile.readAsString()) as Map<String, dynamic>,
      );
      if (await archive.length() == info.bytes &&
          await _digest(archive) == info.sha256Hex) {
        _manifest = info;
      }
    } on Object {
      /* An incomplete cache is unavailable, never served. */
    }
  }

  Future<LanUpdateManifest> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<LanUpdateManifest> _refresh() async {
    final metadata = await _smallJson(
      _client,
      Uri.https(
        'api.github.com',
        '/repos/Robokks/ai-chatbot/releases/tags/latest',
      ),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'Robokks-ai-chatbot',
      },
    );
    final assets = metadata['assets'];
    if (assets is! List) {
      throw const FormatException('Release has no Windows archive');
    }
    final candidates = assets
        .whereType<Map>()
        .where((a) => a['name'] == windowsUpdateFilename)
        .toList();
    if (candidates.length != 1) {
      throw const FormatException('Release has no unique Windows archive');
    }
    final asset = candidates.single;
    final bytes = asset['size'];
    if (bytes is! int || bytes <= 0 || bytes > maxWindowsUpdateBytes) {
      throw const FormatException('Windows update is too large or empty');
    }
    final uri = Uri.parse(asset['browser_download_url'] as String);
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.startsWith('/Robokks/ai-chatbot/releases/download/') ||
        !uri.path.endsWith('/$windowsUpdateFilename')) {
      throw const FormatException(
        'Release archive is not from the official repository',
      );
    }
    final published = DateTime.parse(metadata['published_at'] as String)
        .toUtc();
    // Asset ID changes on every rolling release, unlike the constant tag name.
    final release = '${metadata['tag_name']} · asset ${asset['id']}';
    await directory.create(recursive: true);
    final part = File('${archive.path}.partial');
    try {
      await _download(_client, uri, part, expectedBytes: bytes);
      final hash = await _digest(part);
      final declaredHash = asset['digest'];
      if (declaredHash is String &&
          declaredHash.startsWith('sha256:') &&
          declaredHash.substring(7) != hash) {
        throw const FormatException('Official release checksum does not match');
      }
      final info = LanUpdateManifest(
        release: release,
        publishedAt: published,
        bytes: bytes,
        sha256Hex: hash,
      );
      // Atomic replacement where supported. If interrupted before the metadata
      // is replaced, load() detects a mismatch and refuses to serve the archive.
      await _locked(() async {
        await Future.wait(_snapshots.map((snapshot) => snapshot.done));
        await part.rename(archive.path);
        final manifestPart = File('${_manifestFile.path}.partial');
        await manifestPart.writeAsString(
          jsonEncode(info.toJson()),
          flush: true,
        );
        await manifestPart.rename(_manifestFile.path);
        _manifest = info;
      });
      return info;
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// A bounded, backpressure-aware read of one immutable cache generation.
class LanUpdateSnapshot {
  LanUpdateSnapshot._(this.manifest, this._handle, this._onClose);
  final LanUpdateManifest manifest;
  final RandomAccessFile _handle;
  final void Function() _onClose;
  final _done = Completer<void>();
  Future<void> get done => _done.future;
  bool _closed = false;
  Future<List<int>>? _reading;
  Stream<List<int>> read() async* {
    try {
      while (!_closed) {
        _reading = _handle.read(64 * 1024);
        final bytes = await _reading!;
        _reading = null;
        if (_closed || bytes.isEmpty) {
          break;
        }
        yield bytes;
      }
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return _done.future;
    _closed = true;
    try {
      try {
        await _reading;
      } catch (_) {}
      await _handle.close();
    } finally {
      _onClose();
      _done.complete();
    }
  }
}

/// Uses a paired PC's key on the LAN only. Both endpoints must be protected by
/// Main's access rules, including all relay ancestors and Stop all.
class LanUpdateClient {
  LanUpdateClient({
    required this.baseUrl,
    required this.keyProvider,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null {
    final uri = Uri.parse(baseUrl);
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid Main address');
    }
  }
  final String baseUrl;
  final Future<String?> Function() keyProvider;
  final http.Client _client;
  final bool _ownsClient;
  bool _downloading = false;
  Uri _url(String path) => Uri.parse(baseUrl).replace(path: path);
  Future<Map<String, String>> _headers() async {
    final key = await keyProvider();
    if (key == null ||
        key.isEmpty ||
        key.contains('\r') ||
        key.contains('\n')) {
      throw const FormatException(
        'Pair with Main before downloading an update',
      );
    }
    return {'Authorization': 'Bearer $key'};
  }

  Future<LanUpdateManifest> fetchManifest() async => LanUpdateManifest.fromJson(
    await _smallJson(
      _client,
      _url('/updates/windows/manifest'),
      headers: await _headers(),
    ),
  );

  Future<File> downloadTo(
    Directory directory,
    LanUpdateManifest manifest,
  ) async {
    if (_downloading) throw StateError('An update download is already running');
    _downloading = true;
    File? part;
    try {
      // Revalidate caller-provided metadata before allocating disk space.
      LanUpdateManifest.fromJson(manifest.toJson());
      await directory.create(recursive: true);
      final output = File('${directory.path}/$windowsUpdateFilename');
      if (await output.exists()) {
        if (await output.length() == manifest.bytes &&
            await _digest(output) == manifest.sha256Hex) {
          return output;
        }
        throw const FileSystemException(
          'A different update already exists. Choose an empty folder.',
        );
      }
      part = File('${output.path}.partial');
      await _download(
        _client,
        _url('/updates/windows/archive'),
        part,
        expectedBytes: manifest.bytes,
        headers: await _headers(),
        followRedirects: false,
      );
      if (await _digest(part) != manifest.sha256Hex) {
        throw const FormatException(
          'Update checksum mismatch. Ask Main to refresh its cache.',
        );
      }
      return await part.rename(output.path);
    } finally {
      if (part != null && await part.exists()) await part.delete();
      _downloading = false;
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<Map<String, dynamic>> _smallJson(
  http.Client client,
  Uri url, {
  Map<String, String> headers = const {},
}) async {
  final response = await client
      .send(
        http.Request('GET', url)
          ..headers.addAll(headers)
          ..followRedirects = false,
      )
      .timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    await response.stream.listen(null).cancel();
    throw HttpException('Update service returned ${response.statusCode}');
  }
  final bytes = <int>[];
  await for (final chunk in response.stream.timeout(
    const Duration(seconds: 30),
  )) {
    if (bytes.length + chunk.length > 512 * 1024) {
      throw const FormatException('Update metadata is too large');
    }
    bytes.addAll(chunk);
  }
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

Future<void> _download(
  http.Client client,
  Uri url,
  File output, {
  required int expectedBytes,
  Map<String, String> headers = const {},
  bool followRedirects = true,
}) async {
  final response = await client
      .send(
        http.Request('GET', url)
          ..headers.addAll(headers)
          ..followRedirects = followRedirects
          ..maxRedirects = 5,
      )
      .timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    await response.stream.listen(null).cancel();
    throw HttpException('Update download returned ${response.statusCode}');
  }
  if (response.contentLength != null &&
      response.contentLength != expectedBytes) {
    await response.stream.listen(null).cancel();
    throw const FormatException(
      'Update size changed. Refresh the update information.',
    );
  }
  final sink = output.openWrite();
  var bytes = 0;
  final elapsed = Stopwatch()..start();
  try {
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 60),
    )) {
      if (elapsed.elapsed > const Duration(minutes: 15)) {
        throw const HttpException('Update download took too long');
      }
      bytes += chunk.length;
      if (bytes > expectedBytes || bytes > maxWindowsUpdateBytes) {
        throw const FormatException('Update exceeded its declared size');
      }
      sink.add(chunk);
    }
    await sink.flush();
    if (bytes != expectedBytes) {
      throw const FormatException('Update download was incomplete');
    }
  } finally {
    await sink.close();
  }
}

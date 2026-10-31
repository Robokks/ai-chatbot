import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class DownloadCancelled implements Exception {}

/// The download stopped part-way (network lost, app closed, server error).
/// The partial file is kept so the download can resume.
class DownloadInterrupted implements Exception {
  DownloadInterrupted(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Transport used by [LocalModelStore]. Implementations must resume an
/// earlier partial download of the same model id when they can.
abstract class ModelDownloader {
  Future<void> init() async {}

  /// Downloads [url] and returns the path of the complete file, which may be
  /// [partPath] or another location chosen by the platform.
  Future<String> download({
    required String id,
    required String url,
    required String partPath,
    required String displayName,
    required void Function(double progress) onProgress,
    void Function(String? status)? onStatus,
  });

  Future<void> cancel(String id);

  /// Drops any partial data for [id].
  Future<void> discard(String id, String partPath);

  /// Downloads left by an earlier app session: id → `true` when still
  /// running (or finished but not yet collected), `false` when stopped.
  Future<Map<String, bool>> previous() async => const {};
}

/// SHA-256 of a file, run off the UI thread with `compute`.
Future<String> sha256OfFile(String path) async {
  final out = _DigestSink();
  final hasher = sha256.startChunkedConversion(out);
  await for (final chunk in File(path).openRead()) {
    hasher.add(chunk);
  }
  hasher.close();
  return out.value.toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Plain in-app HTTP download with resume via `Range` requests. Stops when
/// the app is suspended; used on platforms without a background downloader.
class HttpModelDownloader extends ModelDownloader {
  HttpModelDownloader([http.Client? client]) : _client = client ?? http.Client();

  final http.Client _client;
  final Set<String> _cancelled = {};

  @override
  Future<String> download({
    required String id,
    required String url,
    required String partPath,
    required String displayName,
    required void Function(double progress) onProgress,
    void Function(String? status)? onStatus,
  }) async {
    _cancelled.remove(id);
    final part = File(partPath);
    var have = await part.exists() ? await part.length() : 0;
    final req = http.Request('GET', Uri.parse(url));
    if (have > 0) req.headers['range'] = 'bytes=$have-';

    final http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } catch (e) {
      throw DownloadInterrupted('No connection. Tap Resume to continue.');
    }
    if (res.statusCode == 416 && have > 0) return partPath; // already complete
    if (res.statusCode == 200) {
      have = 0; // server ignored the range: start over
    } else if (res.statusCode != 206) {
      throw HttpException(res.statusCode == 401 || res.statusCode == 403
          ? 'This model needs a Hugging Face login (status ${res.statusCode}).'
          : 'Download failed (status ${res.statusCode}).');
    }

    final length = res.contentLength;
    final total = length == null ? 0 : length + have;
    var received = have;
    var lastNotify = DateTime.now();
    final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in res.stream) {
        if (_cancelled.contains(id)) throw DownloadCancelled();
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && DateTime.now().difference(lastNotify).inMilliseconds > 200) {
          onProgress((received / total).clamp(0, 1).toDouble());
          lastNotify = DateTime.now();
        }
      }
    } on DownloadCancelled {
      rethrow;
    } catch (e) {
      throw DownloadInterrupted('Download stopped. Tap Resume to continue.');
    } finally {
      await sink.close();
      _cancelled.remove(id);
    }
    if (total > 0 && received < total) {
      throw DownloadInterrupted('Download stopped. Tap Resume to continue.');
    }
    return partPath;
  }

  @override
  Future<void> cancel(String id) async => _cancelled.add(id);

  @override
  Future<void> discard(String id, String partPath) async {
    final f = File(partPath);
    if (await f.exists()) await f.delete();
  }
}

/// System background download (Android WorkManager / user-initiated job with
/// a progress notification; native on Windows). Keeps going when the user
/// switches apps, retries and resumes after network drops, and survives app
/// restarts.
class BackgroundModelDownloader extends ModelDownloader {
  static const _group = 'models';
  final _fd = FileDownloader();
  bool _started = false;

  static String _taskId(String id) => 'model-$id';

  @override
  Future<void> init() async {
    if (_started) return;
    _started = true;
    _fd.configureNotificationForGroup(
      _group,
      running: const TaskNotification('Downloading model', '{displayName} · {progress}'),
      complete: const TaskNotification('Model downloaded', '{displayName} is ready to use offline'),
      error: const TaskNotification('Download stopped', 'Open Chatbot to resume {displayName}'),
      paused: const TaskNotification('Download paused', '{displayName}'),
      progressBar: true,
    );
    await _fd.start(autoCleanDatabase: true);
  }

  DownloadTask _task(String id, String url, String partPath, String displayName) {
    final file = File(partPath);
    return DownloadTask(
      taskId: _taskId(id),
      url: url,
      filename: file.uri.pathSegments.last,
      directory: 'models',
      baseDirectory: BaseDirectory.applicationSupport,
      group: _group,
      displayName: displayName,
      retries: 5,
      stallTimeout: const Duration(seconds: 60),
      transferHints: {TransferHint.userInitiated, TransferHint.largeFile},
    );
  }

  Future<void> _askForNotifications() async {
    try {
      const type = PermissionType.notifications;
      if (await _fd.permissions.status(type) != PermissionStatus.granted) {
        await _fd.permissions.request(type);
      }
    } catch (_) {
      // Downloads still work without a notification, just not as UIDT jobs.
    }
  }

  @override
  Future<String> download({
    required String id,
    required String url,
    required String partPath,
    required String displayName,
    required void Function(double progress) onProgress,
    void Function(String? status)? onStatus,
  }) async {
    await init();
    await _askForNotifications();
    final existing = _fd.transfers.forId(_taskId(id));
    Transfer transfer;
    if (existing != null &&
        existing.status == TaskStatus.complete &&
        await (await existing.file).exists()) {
      transfer = existing;
    } else if (existing != null && existing.status.isNotFinalState) {
      transfer = existing; // still running from before: re-attach
    } else if (existing != null &&
        (existing.status == TaskStatus.failed || existing.status == TaskStatus.paused) &&
        await existing.resume()) {
      transfer = existing; // continue from the partial data
    } else {
      transfer = await _fd.transfers.start(_task(id, url, partPath, displayName));
    }
    return _await(transfer, onProgress, onStatus);
  }

  Future<String> _await(
    Transfer t,
    void Function(double) onProgress,
    void Function(String?)? onStatus,
  ) async {
    void progress() {
      final p = t.progress;
      if (p != null && p >= 0 && p <= 1) onProgress(p);
    }

    void status() {
      onStatus?.call(switch (t.holdReason) {
        TransferHoldReason.offline => 'Waiting for internet…',
        TransferHoldReason.waitingForWiFi => 'Waiting for Wi-Fi…',
        _ => t.status == TaskStatus.waitingToRetry ? 'Connection lost, retrying…' : null,
      });
    }

    t.progressNotifier.addListener(progress);
    t.holdReasonNotifier.addListener(status);
    t.statusNotifier.addListener(status);
    progress();
    try {
      final r = await t.result;
      return switch (r.status) {
        TaskStatus.complete => (await t.file).path,
        TaskStatus.canceled => throw DownloadCancelled(),
        _ => throw DownloadInterrupted(
            '${r.exception?.description ?? 'Download stopped'}. Tap Resume to continue.'),
      };
    } finally {
      t.progressNotifier.removeListener(progress);
      t.holdReasonNotifier.removeListener(status);
      t.statusNotifier.removeListener(status);
    }
  }

  @override
  Future<void> cancel(String id) async => _fd.transfers.forId(_taskId(id))?.cancel();

  @override
  Future<void> discard(String id, String partPath) async {
    final t = _fd.transfers.forId(_taskId(id));
    if (t != null && t.status.isNotFinalState) await t.cancel();
    final f = File(partPath);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<Map<String, bool>> previous() async {
    await init();
    return {
      for (final t in _fd.transfers.all(group: _group))
        if (t.taskId.startsWith('model-') && t.status != TaskStatus.canceled)
          t.taskId.substring(6): t.status.isNotFinalState || t.status == TaskStatus.complete,
    };
  }
}

/// Background downloads where the platform supports them; in-app otherwise.
ModelDownloader defaultModelDownloader([http.Client? client]) =>
    !kIsWeb && (Platform.isAndroid || Platform.isWindows)
        ? BackgroundModelDownloader()
        : HttpModelDownloader(client);

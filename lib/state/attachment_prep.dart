import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/llm/llm_provider.dart';
import '../data/local/picture_reader.dart';
import '../data/models.dart';
import 'app_state.dart';

/// The user's answer to "Read this picture with Claude?".
enum CloudReadChoice { yes, always, no }

/// A picture waiting for the user's OK to be read by a cloud model.
class PictureReadRequest {
  PictureReadRequest(this.attachment, this.provider);
  final Attachment attachment;
  final ProviderKind provider;
  final Completer<CloudReadChoice> answer = Completer<CloudReadChoice>();
}

/// Turns PDF pages into pictures (for scanned PDFs). Returns at most
/// [maxPages] pages and the page count.
typedef PdfPageRenderer = Future<(List<Uint8List>, int)> Function(Uint8List pdf, int maxPages);

/// Makes attachments understandable for models that can't see: reads
/// pictures and scanned PDFs into text (once; the text is kept with the chat).
class AttachmentPrep {
  AttachmentPrep(this.app, {LocalPictureReader? local, this.renderPdf})
      : local = local ?? LocalPictureReader();

  final AppState app;
  final LocalPictureReader local;
  final PdfPageRenderer? renderPdf;

  static const _alwaysKey = 'reader.cloudAlways';

  /// Online providers that can read pictures, in the order they are tried:
  /// free ones first, then paid. The offline reader is the last fallback.
  static const cloudReaders = [
    ProviderKind.gemini,
    ProviderKind.mistral,
    ProviderKind.github,
    ProviderKind.anthropic,
    ProviderKind.openai,
  ];

  /// Providers the user said "Always" for.
  Set<ProviderKind> get alwaysAllowed {
    final raw = app.storage.getSetting(_alwaysKey);
    if (raw == null) return {};
    return {for (final n in jsonDecode(raw) as List) ?ProviderKind.values.asNameMap()[n]};
  }

  Future<void> setAlways(ProviderKind k, bool on) {
    final s = alwaysAllowed;
    on ? s.add(k) : s.remove(k);
    return app.storage.setSetting(_alwaysKey, jsonEncode([for (final x in s) x.name]));
  }

  static int get maxPdfPages => Platform.isAndroid || Platform.isIOS ? 8 : 20;

  /// Reads what [target] can't take directly, in the last user message of
  /// [history] and any older ones not read yet. [ask] shows the cloud
  /// question; without it only offline readers (and "Always" clouds) are used.
  Future<void> prepare(
    List<Message> history,
    ProviderKind target, {
    void Function(String status)? onStatus,
    bool Function()? stopped,
    Future<CloudReadChoice> Function(Attachment a, ProviderKind cloud)? ask,
    bool? targetSees,
  }) async {
    final todo = <Attachment>[
      for (final m in history)
        if (m.role == Role.user)
          for (final a in m.attachments)
            if (_needsReading(a, target, targetSees)) a,
    ];
    final declined = <ProviderKind>{};
    for (var i = 0; i < todo.length; i++) {
      if (stopped?.call() ?? false) return;
      final a = todo[i];
      final what = a.kind == AttachmentKind.pdf ? 'scanned PDF' : 'picture';
      onStatus?.call(todo.length == 1 ? 'Reading the $what…' : 'Reading $what ${i + 1} of ${todo.length}…');
      try {
        a.text = a.kind == AttachmentKind.pdf
            ? await _readPdf(a, onStatus, stopped, ask, declined)
            : await _readPicture(a.bytes!, a, ask, declined);
      } on _NoReader {
        // Left unread: the AI is told a picture couldn't be read.
      } on PictureReadException catch (e) {
        a.readError = e.message;
      } catch (e) {
        a.readError = 'Could not read ${a.name}: $e';
      }
    }
  }

  bool _needsReading(Attachment a, ProviderKind target, bool? targetSees) {
    if (a.text != null || a.bytes == null) return false;
    if (a.kind == AttachmentKind.image) return !(targetSees ?? target.images);
    if (a.kind == AttachmentKind.pdf) return !target.pdf && renderPdf != null;
    return false;
  }

  Future<String> _readPdf(
    Attachment a,
    void Function(String)? onStatus,
    bool Function()? stopped,
    Future<CloudReadChoice> Function(Attachment, ProviderKind)? ask,
    Set<ProviderKind> declined,
  ) async {
    final (pages, total) = await renderPdf!(a.bytes!, maxPdfPages);
    final out = StringBuffer('Scanned PDF, read page by page:\n');
    for (var i = 0; i < pages.length; i++) {
      if (stopped?.call() ?? false) break;
      onStatus?.call('Reading page ${i + 1} of ${pages.length} of ${a.name}…');
      final text = await _readPicture(pages[i], a, ask, declined, pdfPage: true);
      out
        ..writeln('\n--- Page ${i + 1} ---')
        ..writeln(text);
    }
    if (total > pages.length) {
      out.writeln('\n… [only the first ${pages.length} of $total pages were read]');
    }
    return out.toString().trim();
  }

  /// Text of one picture: on this device when a reader is downloaded, else
  /// with a cloud model the user allows.
  Future<String> _readPicture(
    Uint8List bytes,
    Attachment a,
    Future<CloudReadChoice> Function(Attachment, ProviderKind)? ask,
    Set<ProviderKind> declined, {
    bool pdfPage = false,
  }) async {
    // Online first (the user's choice), each provider asked once unless
    // "Always" was picked.
    var saidNo = false;
    for (final k in cloudReaders) {
      if (saidNo || !app.hasKey(k) || declined.contains(k)) continue;
      if (!alwaysAllowed.contains(k)) {
        if (ask == null) continue;
        final choice = await ask(a, k);
        if (choice == CloudReadChoice.no) {
          declined.add(k);
          saidNo = true;
          continue;
        }
        if (choice == CloudReadChoice.always) await setAlways(k, true);
      }
      try {
        final text = await _readWithCloud(k, bytes);
        return pdfPage ? text : '(Read by ${k.label})\n$text';
      } on LlmException {
        declined.add(k); // Limit reached or failed: try the next one.
      }
    }
    final m = app.localModels.installedVisionModel;
    if (m != null && AppState.localSupported) {
      final big = m.sizeMb > 1000;
      final text = await local.read(
        await app.localModels.pathFor(m.id),
        await app.localModels.projectorPathFor(m.id),
        bytes,
        maxSide: pdfPage ? (big ? 1280 : 1024) : (big ? 1024 : 768),
      );
      return pdfPage ? text : '(Read by ${m.name.replaceAll(' (picture reader)', '')} on this device)\n$text';
    }
    throw const _NoReader();
  }

  Future<String> _readWithCloud(ProviderKind k, Uint8List bytes) async {
    final settings = app.providers[k]!;
    final llm = app.providerFor(k);
    final picture = Attachment(
        name: 'picture.jpg', mimeType: 'image/jpeg', kind: AttachmentKind.image, size: bytes.length,
        bytes: downscale(bytes, 1568));
    final out = StringBuffer();
    // A fast model is enough to read a picture.
    final model = settings.models.firstWhere((m) => m.contains('flash') || m.contains('mini'),
        orElse: () => settings.models.first);
    await for (final d in llm.streamChat(ChatRequest(
      model: model,
      messages: [Message(role: Role.user, text: pictureReadInstructions, attachments: [picture])],
    ))) {
      out.write(d.text);
    }
    final text = out.toString().trim();
    if (text.isEmpty) throw PictureReadException('${k.label} gave no answer for the picture.');
    return text;
  }
}

class _NoReader implements Exception {
  const _NoReader();
}

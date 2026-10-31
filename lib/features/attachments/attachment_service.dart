import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../data/models.dart';
import 'document_text.dart';

class AttachmentException implements Exception {
  AttachmentException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns picked/dropped files into [Attachment]s: images are downscaled and
/// re-encoded, PDFs get their text extracted, text files are decoded.
class AttachmentService {
  static const maxImageSide = 1568;
  static const maxFileBytes = 30 * 1024 * 1024;
  static const maxTextChars = 400000;

  static const _textExtensions = {
    'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'jsonl', 'xml', 'yaml', 'yml',
    'toml', 'ini', 'cfg', 'conf', 'log', 'html', 'htm', 'css', 'scss', 'js',
    'jsx', 'ts', 'tsx', 'mjs', 'py', 'rb', 'go', 'rs', 'java', 'kt', 'kts',
    'swift', 'c', 'h', 'cpp', 'hpp', 'cc', 'cs', 'php', 'dart', 'sh', 'bash',
    'zsh', 'ps1', 'bat', 'sql', 'r', 'lua', 'pl', 'scala', 'vue', 'svelte',
    'gradle', 'properties', 'env', 'gitignore', 'dockerfile', 'tex', 'srt',
  };

  static const pickerExtensions = [
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp', 'pdf', ..._textExtensionsList,
    ...documentExtensions, 'doc', 'xls', 'ppt',
  ];
  static const _textExtensionsList = [
    'txt', 'md', 'csv', 'json', 'xml', 'yaml', 'yml', 'log', 'html', 'css',
    'js', 'ts', 'py', 'java', 'kt', 'c', 'cpp', 'h', 'cs', 'go', 'rs', 'dart',
    'sh', 'sql', 'swift', 'php', 'rb',
  ];

  final _imagePicker = ImagePicker();

  Future<List<Attachment>> pickFiles() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Attach files',
      type: FileType.custom,
      allowedExtensions: pickerExtensions,
    );
    return [for (final f in files) ...await fromBytesAll(f.name, await f.readAsBytes())];
  }

  Future<List<Attachment>> pickPhotos() async {
    final images = await _imagePicker.pickMultiImage();
    return [for (final x in images) await fromXFile(x)];
  }

  Future<Attachment?> takePhoto() async {
    final x = await _imagePicker.pickImage(source: ImageSource.camera);
    return x == null ? null : fromXFile(x);
  }

  Future<Attachment> fromXFile(XFile x) async => fromBytes(x.name, await x.readAsBytes());

  /// Like [fromBytesAll] for a dropped or picked [XFile].
  Future<List<Attachment>> fromXFileAll(XFile x) async => fromBytesAll(x.name, await x.readAsBytes());

  /// The file itself plus, for office files, the pictures inside it (so the
  /// AI can see or read them too).
  Future<List<Attachment>> fromBytesAll(String name, Uint8List bytes) async {
    if (!isDocumentName(name)) return [await fromBytes(name, bytes)];
    final doc = _document(name, bytes);
    final out = [doc.$1];
    for (final (picName, picBytes) in doc.$2) {
      try {
        out.add(_image('$name – $picName', picBytes));
      } catch (_) {
        // A picture format we can't decode (e.g. EMF): skip it.
      }
    }
    return out;
  }

  (Attachment, List<(String, Uint8List)>) _document(String name, Uint8List bytes) {
    final ExtractedDocument d;
    try {
      d = extractDocument(name, bytes);
    } on DocumentException catch (e) {
      throw AttachmentException(e.message);
    }
    return (
      Attachment(
        name: name,
        mimeType: d.mimeType,
        kind: AttachmentKind.text,
        size: bytes.length,
        text: '[${d.label}]\n${d.text}',
      ),
      d.pictures,
    );
  }

  Future<Attachment> fromBytes(String name, Uint8List bytes) async {
    if (bytes.length > maxFileBytes) {
      throw AttachmentException('$name is larger than 30 MB.');
    }
    final mime = lookupMimeType(name, headerBytes: bytes) ?? 'application/octet-stream';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';

    if (mime.startsWith('image/')) return _image(name, bytes);
    if (mime == 'application/pdf') return _pdf(name, bytes);
    if (isDocumentName(name)) return _document(name, bytes).$1;
    if (mime.startsWith('text/') || _textExtensions.contains(ext) || _looksLikeText(bytes)) {
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.length > maxTextChars) {
        throw AttachmentException('$name is too long to send as text.');
      }
      return Attachment(
        name: name,
        mimeType: mime.startsWith('text/') ? mime : 'text/plain',
        kind: AttachmentKind.text,
        size: bytes.length,
        text: text,
      );
    }
    throw AttachmentException('$name: this file type is not supported.');
  }

  Attachment _image(String name, Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw AttachmentException('Could not read image $name.');
    var out = decoded;
    final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
    if (longest > maxImageSide) {
      out = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxImageSide)
          : img.copyResize(decoded, height: maxImageSide);
    }
    final hasAlpha = out.hasAlpha && out.numChannels == 4;
    final encoded = hasAlpha ? img.encodePng(out) : img.encodeJpg(out, quality: 85);
    final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
    return Attachment(
      name: '$base.${hasAlpha ? 'png' : 'jpg'}',
      mimeType: hasAlpha ? 'image/png' : 'image/jpeg',
      kind: AttachmentKind.image,
      size: encoded.length,
      bytes: encoded,
    );
  }

  Attachment _pdf(String name, Uint8List bytes) {
    String? text;
    try {
      final doc = PdfDocument(inputBytes: bytes);
      text = PdfTextExtractor(doc).extractText();
      doc.dispose();
    } catch (_) {
      // Encrypted or malformed: native-PDF providers may still read it.
    }
    return Attachment(
      name: name,
      mimeType: 'application/pdf',
      kind: AttachmentKind.pdf,
      size: bytes.length,
      bytes: bytes,
      text: text == null || text.trim().isEmpty ? null : text,
    );
  }

  static bool _looksLikeText(Uint8List bytes) {
    final sample = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
    return !sample.contains(0);
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

/// Text (as markdown) and pictures pulled out of an office file.
class ExtractedDocument {
  ExtractedDocument({
    required this.text,
    required this.label,
    required this.mimeType,
    this.pictures = const [],
    this.cut = false,
  });

  final String text;

  /// "Word document", "Excel workbook", …
  final String label;
  final String mimeType;

  /// Pictures inside the file: (name, bytes).
  final List<(String, Uint8List)> pictures;

  /// Whether the text was shortened.
  final bool cut;
}

class DocumentException implements Exception {
  const DocumentException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// File types read by [extractDocument], by extension.
const documentExtensions = {
  'docx', 'docm', 'xlsx', 'xlsm', 'pptx', 'pptm', 'odt', 'ods', 'odp', 'rtf', 'epub', 'zip',
};

/// Old binary Office files we can't read, with the format to save as.
const _oldOffice = {'doc': 'docx', 'xls': 'xlsx', 'ppt': 'pptx'};

const maxDocumentChars = 200000;
const maxSheetRows = 2000;
const maxPictures = 10;

const _mimes = {
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'docm': 'application/vnd.ms-word.document.macroEnabled.12',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'xlsm': 'application/vnd.ms-excel.sheet.macroEnabled.12',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'pptm': 'application/vnd.ms-powerpoint.presentation.macroEnabled.12',
  'odt': 'application/vnd.oasis.opendocument.text',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'odp': 'application/vnd.oasis.opendocument.presentation',
  'rtf': 'application/rtf',
  'epub': 'application/epub+zip',
  'zip': 'application/zip',
};

String _ext(String name) => name.contains('.') ? name.split('.').last.toLowerCase() : '';

/// Whether [name] is a document [extractDocument] handles (or explains).
bool isDocumentName(String name) {
  final e = _ext(name);
  return documentExtensions.contains(e) || _oldOffice.containsKey(e);
}

/// Reads an office file. Throws [DocumentException] with a plain message
/// when it can't.
ExtractedDocument extractDocument(String name, Uint8List bytes) {
  final ext = _ext(name);
  final newer = _oldOffice[ext];
  if (newer != null) {
    throw DocumentException('$name is an old Office file. Open it and save it as .$newer, '
        'then attach it again.');
  }
  if (ext == 'rtf') {
    return _finish(_rtf(bytes), 'Rich text document', ext, const []);
  }
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
    if (zip.files.isEmpty) throw const FormatException('empty');
  } catch (_) {
    throw DocumentException('Could not open $name. The file may be damaged or password-protected.');
  }
  try {
    return switch (ext) {
      'docx' || 'docm' => _finish(_docx(zip), 'Word document', ext, _pictures(zip, 'word/media/')),
      'xlsx' || 'xlsm' => _xlsx(zip, ext),
      'pptx' || 'pptm' => _finish(_pptx(zip), 'PowerPoint presentation', ext, _pictures(zip, 'ppt/media/')),
      'odt' || 'ods' || 'odp' => _finish(_odf(zip), switch (ext) {
          'odt' => 'Text document',
          'ods' => 'Spreadsheet',
          _ => 'Presentation',
        }, ext, _pictures(zip, 'Pictures/')),
      'epub' => _finish(_epub(zip), 'E-book', ext, const []),
      'zip' => _zipListing(zip),
      _ => throw DocumentException('$name: this file type is not supported.'),
    };
  } on DocumentException {
    rethrow;
  } catch (e) {
    throw DocumentException('Could not read $name ($e).');
  }
}

ExtractedDocument _finish(String text, String label, String ext, List<(String, Uint8List)> pictures) {
  var t = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  var cut = false;
  if (t.length > maxDocumentChars) {
    t = '${t.substring(0, maxDocumentChars)}\n\n… [the rest of the file was cut: '
        '${t.length - maxDocumentChars} more characters]';
    cut = true;
  }
  if (t.isEmpty) t = '(No text found in this file.)';
  return ExtractedDocument(text: t, label: label, mimeType: _mimes[ext]!, pictures: pictures, cut: cut);
}

String? _read(Archive zip, String path) {
  final f = zip.findFile(path);
  if (f == null || !f.isFile) return null;
  return utf8.decode(f.content, allowMalformed: true);
}

XmlDocument? _xml(Archive zip, String path) {
  final s = _read(zip, path);
  return s == null ? null : XmlDocument.parse(s);
}

Iterable<XmlElement> _all(XmlNode n, String local) =>
    n.descendants.whereType<XmlElement>().where((e) => e.name.local == local);

String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

const _pictureTypes = {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'};

List<(String, Uint8List)> _pictures(Archive zip, String folder) {
  final out = <(String, Uint8List)>[];
  for (final f in zip.files) {
    if (out.length >= maxPictures) break;
    if (!f.isFile || !f.name.startsWith(folder)) continue;
    if (!_pictureTypes.contains(_ext(f.name))) continue;
    final bytes = f.content;
    if (bytes.length < 1024) continue; // Bullets and tiny icons.
    out.add((f.name.split('/').last, bytes));
  }
  return out;
}

String _cell(String s) => s.replaceAll('|', r'\|').replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

/// Rows as a markdown table; the first row is the header.
String _table(List<List<String>> rows) {
  final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
  if (width == 0) return '';
  final lines = <String>[];
  for (var i = 0; i < rows.length; i++) {
    final r = [for (var c = 0; c < width; c++) c < rows[i].length ? _cell(rows[i][c]) : ''];
    lines.add('| ${r.join(' | ')} |');
    if (i == 0) lines.add('|${List.filled(width, ' --- ').join('|')}|');
  }
  return lines.join('\n');
}

// Word

String _docx(Archive zip) {
  final doc = _xml(zip, 'word/document.xml');
  if (doc == null) throw const DocumentException('This Word file has no document inside.');
  final out = StringBuffer();

  String paragraph(XmlElement p) {
    final b = StringBuffer();
    for (final n in p.descendants.whereType<XmlElement>()) {
      switch (n.name.local) {
        case 't':
          b.write(n.innerText);
        case 'tab':
          b.write('\t');
        case 'br' || 'cr':
          b.write('\n');
      }
    }
    return b.toString();
  }

  void visit(XmlElement e) {
    switch (e.name.local) {
      case 'p':
        final text = paragraph(e).trimRight();
        final style = _all(e, 'pStyle').map((s) => _attr(s, 'val') ?? '').firstOrNull ?? '';
        final heading = RegExp(r'^(?:Heading|heading)\s?(\d)').firstMatch(style);
        if (text.isEmpty) {
          out.writeln();
        } else if (style == 'Title') {
          out.writeln('# $text');
        } else if (heading != null) {
          out.writeln('${'#' * (int.parse(heading.group(1)!) + 1).clamp(2, 6)} $text');
        } else if (_all(e, 'numPr').isNotEmpty) {
          out.writeln('- $text');
        } else {
          out.writeln(text);
        }
      case 'tbl':
        final rows = <List<String>>[
          for (final tr in e.childElements.where((c) => c.name.local == 'tr'))
            [
              for (final tc in tr.childElements.where((c) => c.name.local == 'tc'))
                _all(tc, 'p').map(paragraph).where((t) => t.trim().isNotEmpty).join(' '),
            ],
        ];
        out
          ..writeln()
          ..writeln(_table(rows))
          ..writeln();
      default:
        for (final c in e.childElements) {
          visit(c);
        }
    }
  }

  final body = _all(doc, 'body').firstOrNull;
  if (body != null) visit(body);
  return out.toString();
}

// Excel

int _column(String ref) {
  var n = 0;
  for (final c in ref.codeUnits) {
    if (c < 65 || c > 90) break;
    n = n * 26 + (c - 64);
  }
  return n - 1;
}

ExtractedDocument _xlsx(Archive zip, String ext) {
  final shared = <String>[
    for (final si in _all(_xml(zip, 'xl/sharedStrings.xml') ?? XmlDocument(), 'si'))
      _all(si, 't').map((t) => t.innerText).join(),
  ];
  final workbook = _xml(zip, 'xl/workbook.xml');
  if (workbook == null) throw const DocumentException('This Excel file has no workbook inside.');
  final rels = <String, String>{
    for (final r in _all(_xml(zip, 'xl/_rels/workbook.xml.rels') ?? XmlDocument(), 'Relationship'))
      _attr(r, 'Id') ?? '': _attr(r, 'Target') ?? '',
  };
  final out = StringBuffer();
  var cut = false;
  for (final sheet in _all(workbook, 'sheet')) {
    final name = _attr(sheet, 'name') ?? 'Sheet';
    var target = rels[_attr(sheet, 'id')] ?? '';
    if (target.startsWith('/')) {
      target = target.substring(1);
    } else {
      target = 'xl/$target';
    }
    final data = _xml(zip, target);
    if (data == null) continue;
    final rows = <List<String>>[];
    for (final row in _all(data, 'row')) {
      if (rows.length >= maxSheetRows) {
        cut = true;
        break;
      }
      final cells = <String>[];
      for (final c in row.childElements.where((e) => e.name.local == 'c')) {
        final col = _column(_attr(c, 'r') ?? '');
        final type = _attr(c, 't');
        final v = c.childElements.where((e) => e.name.local == 'v').firstOrNull?.innerText ?? '';
        final value = switch (type) {
          's' => (int.tryParse(v) ?? -1) >= 0 && int.parse(v) < shared.length ? shared[int.parse(v)] : '',
          'inlineStr' => _all(c, 't').map((t) => t.innerText).join(),
          'b' => v == '1' ? 'TRUE' : 'FALSE',
          _ => v,
        };
        final at = col >= 0 ? col : cells.length;
        if (at > 200) continue;
        while (cells.length < at) {
          cells.add('');
        }
        cells.add(value);
      }
      if (cells.any((c) => c.trim().isNotEmpty)) rows.add(cells);
    }
    out
      ..writeln('## Sheet: $name')
      ..writeln()
      ..writeln(rows.isEmpty ? '(empty)' : _table(rows))
      ..writeln();
    if (rows.length >= maxSheetRows) out.writeln('… [only the first $maxSheetRows rows are shown]\n');
  }
  final doc = _finish(out.toString(), 'Excel workbook', ext, _pictures(zip, 'xl/media/'));
  return cut
      ? ExtractedDocument(
          text: doc.text, label: doc.label, mimeType: doc.mimeType, pictures: doc.pictures, cut: true)
      : doc;
}

// PowerPoint

String _pptx(Archive zip) {
  int number(String path) => int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(path)?.group(1) ?? '') ?? 0;
  final slides = [
    for (final f in zip.files)
      if (f.isFile && RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name)) f.name,
  ]..sort((a, b) => number(a).compareTo(number(b)));
  String text(XmlDocument d) => [
        for (final p in _all(d, 'p'))
          _all(p, 't').map((t) => t.innerText).join(),
      ].where((l) => l.trim().isNotEmpty).join('\n');

  final out = StringBuffer();
  for (final s in slides) {
    final d = _xml(zip, s);
    if (d == null) continue;
    out
      ..writeln('## Slide ${number(s)}')
      ..writeln(text(d));
    final rels = _xml(zip, s.replaceFirst('slides/', 'slides/_rels/').replaceFirst(RegExp(r'\.xml$'), '.xml.rels'));
    for (final r in rels == null ? const <XmlElement>[] : _all(rels, 'Relationship')) {
      final t = _attr(r, 'Target') ?? '';
      if (!t.contains('notesSlide')) continue;
      final notes = _xml(zip, 'ppt/${t.replaceFirst('../', '')}');
      final n = notes == null ? '' : text(notes).trim();
      if (n.isNotEmpty) out.writeln('Speaker notes: $n');
    }
    out.writeln();
  }
  return out.toString();
}

// OpenDocument

String _odf(Archive zip) {
  final doc = _xml(zip, 'content.xml');
  if (doc == null) throw const DocumentException('This file has no content inside.');
  final out = StringBuffer();
  var slide = 0;

  String text(XmlElement e) {
    final b = StringBuffer();
    for (final n in e.descendants) {
      if (n is XmlText) b.write(n.value);
      if (n is XmlElement) {
        switch (n.name.local) {
          case 'tab':
            b.write('\t');
          case 'line-break':
            b.write('\n');
          case 's':
            b.write(' ' * (int.tryParse(_attr(n, 'c') ?? '') ?? 1));
        }
      }
    }
    return b.toString();
  }

  void visit(XmlElement e) {
    switch (e.name.local) {
      case 'h':
        out.writeln('## ${text(e).trim()}');
      case 'p':
        out.writeln(text(e));
      case 'page':
        slide++;
        out.writeln('\n## Slide $slide');
        for (final c in e.childElements) {
          visit(c);
        }
      case 'table':
        final name = _attr(e, 'name');
        final rows = <List<String>>[];
        for (final row in _all(e, 'table-row')) {
          if (rows.length >= maxSheetRows) break;
          final cells = <String>[];
          for (final c in row.childElements.where((c) => c.name.local == 'table-cell')) {
            final repeat = (int.tryParse(_attr(c, 'number-columns-repeated') ?? '') ?? 1).clamp(1, 50);
            final v = _all(c, 'p').map(text).join(' ');
            for (var i = 0; i < repeat; i++) {
              cells.add(v);
            }
          }
          while (cells.isNotEmpty && cells.last.trim().isEmpty) {
            cells.removeLast();
          }
          if (cells.isNotEmpty) rows.add(cells);
        }
        if (name != null) out.writeln('\n## Sheet: $name');
        out
          ..writeln()
          ..writeln(rows.isEmpty ? '(empty)' : _table(rows))
          ..writeln();
      default:
        for (final c in e.childElements) {
          visit(c);
        }
    }
  }

  visit(doc.rootElement);
  return out.toString();
}

// RTF

String _rtf(Uint8List bytes) {
  final s = latin1.decode(bytes, allowInvalid: true);
  final out = StringBuffer();
  var depth = 0;
  // Groups whose text isn't content (fonts, colors, pictures, ...).
  final skipFrom = <int>[];
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == '{') {
      depth++;
      final m = RegExp(r'\{\\(\*|fonttbl|colortbl|stylesheet|info|pict|header|footer)')
          .matchAsPrefix(s, i);
      if (m != null && skipFrom.isEmpty) skipFrom.add(depth);
      i++;
      continue;
    }
    if (ch == '}') {
      if (skipFrom.isNotEmpty && skipFrom.last == depth) skipFrom.removeLast();
      depth--;
      i++;
      continue;
    }
    final skipping = skipFrom.isNotEmpty;
    if (ch == '\\') {
      final hex = RegExp(r"\\'([0-9a-fA-F]{2})").matchAsPrefix(s, i);
      if (hex != null) {
        if (!skipping) out.writeCharCode(int.parse(hex.group(1)!, radix: 16));
        i = hex.end;
        continue;
      }
      final uni = RegExp(r'\\u(-?\d+)\??').matchAsPrefix(s, i);
      if (uni != null) {
        var code = int.parse(uni.group(1)!);
        if (code < 0) code += 65536;
        if (!skipping) out.writeCharCode(code);
        i = uni.end;
        continue;
      }
      final word = RegExp(r'\\([a-zA-Z]+)(-?\d+)? ?').matchAsPrefix(s, i);
      if (word != null) {
        if (!skipping) {
          switch (word.group(1)) {
            case 'par' || 'line' || 'row':
              out.write('\n');
            case 'tab' || 'cell':
              out.write('\t');
          }
        }
        i = word.end;
        continue;
      }
      if (i + 1 < s.length && !skipping && '\\{}'.contains(s[i + 1])) out.write(s[i + 1]);
      i += 2;
      continue;
    }
    if (!skipping && ch != '\r' && ch != '\n') out.write(ch);
    i++;
  }
  return out.toString();
}

// EPUB

const _blockTags = {
  'p', 'div', 'br', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'pre', 'section',
};

String htmlToText(String source) {
  final body = html.parse(source).body;
  if (body == null) return '';
  final b = StringBuffer();
  void walk(dom.Node n) {
    if (n is dom.Text) {
      b.write(n.text.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    if (n is! dom.Element) return;
    final tag = n.localName ?? '';
    if (tag == 'script' || tag == 'style') return;
    if (tag.length == 2 && tag[0] == 'h' && int.tryParse(tag[1]) != null) b.write('\n## ');
    for (final c in n.nodes) {
      walk(c);
    }
    if (_blockTags.contains(tag)) b.write('\n');
  }

  walk(body);
  return b.toString().split('\n').map((l) => l.trim()).join('\n');
}

String _epub(Archive zip) {
  final container = _xml(zip, 'META-INF/container.xml');
  final opfPath = container == null
      ? null
      : _all(container, 'rootfile').map((r) => _attr(r, 'full-path')).firstOrNull;
  if (opfPath == null) throw const DocumentException('This e-book is missing its contents list.');
  final opf = _xml(zip, opfPath);
  if (opf == null) throw const DocumentException('This e-book is missing its contents list.');
  final base = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';
  final manifest = {
    for (final item in _all(opf, 'item')) _attr(item, 'id') ?? '': _attr(item, 'href') ?? '',
  };
  final out = StringBuffer();
  for (final ref in _all(opf, 'itemref')) {
    final href = manifest[_attr(ref, 'idref')];
    if (href == null) continue;
    final page = _read(zip, base + Uri.decodeComponent(href));
    if (page != null) out.writeln(htmlToText(page));
    if (out.length > maxDocumentChars) break;
  }
  return out.toString();
}

// ZIP

const _zipTextTypes = {
  'txt', 'md', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml', 'log', 'html', 'htm', 'css', 'js', 'ts',
  'py', 'java', 'kt', 'c', 'cpp', 'h', 'cs', 'go', 'rs', 'dart', 'sh', 'sql', 'swift', 'php', 'rb',
  'ini', 'toml', 'cfg', 'conf',
};

ExtractedDocument _zipListing(Archive zip) {
  final files = [for (final f in zip.files) if (f.isFile && !f.name.startsWith('__MACOSX/')) f];
  final out = StringBuffer('Files in this ZIP (${files.length}):\n');
  for (final f in files.take(300)) {
    out.writeln('- ${f.name} (${f.size} bytes)');
  }
  if (files.length > 300) out.writeln('- … and ${files.length - 300} more');
  for (final f in files) {
    if (out.length > maxDocumentChars) break;
    if (!_zipTextTypes.contains(_ext(f.name)) || f.size > 200000) continue;
    out
      ..writeln('\n<file name="${f.name}">')
      ..writeln(utf8.decode(f.content, allowMalformed: true))
      ..writeln('</file>');
  }
  final pictures = <(String, Uint8List)>[
    for (final f in files)
      if (_pictureTypes.contains(_ext(f.name)) && f.size >= 1024 && f.size < 20 * 1024 * 1024)
        (f.name.split('/').last, f.content),
  ].take(maxPictures).toList();
  return _finish(out.toString(), 'ZIP archive', 'zip', pictures);
}

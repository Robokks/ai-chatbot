import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/features/attachments/attachment_service.dart';
import 'package:ai_chatbot/features/attachments/document_text.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List zipOf(Map<String, Object> files) {
  final a = Archive();
  files.forEach((name, content) => a.addFile(content is String
      ? ArchiveFile.string(name, content)
      : ArchiveFile.bytes(name, content as List<int>)));
  return ZipEncoder().encodeBytes(a);
}

/// A real 64×64 PNG, big enough not to be skipped as an icon.
final noisy = img.encodePng(img.Image.fromBytes(
    width: 48, height: 48, bytes: Uint8List.fromList(List.generate(48 * 48 * 3, (_) => _rand.nextInt(256))).buffer));
final _rand = Random(1);

const w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';

void main() {
  test('Word: headings, lists, tables and pictures', () {
    final docx = zipOf({
      'word/document.xml': '<w:document $w><w:body>'
          '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Sales report</w:t></w:r></w:p>'
          '<w:p><w:r><w:t xml:space="preserve">Total was </w:t></w:r><w:r><w:t>42 boxes.</w:t></w:r></w:p>'
          '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr><w:r><w:t>First point</w:t></w:r></w:p>'
          '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Month</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Sales</w:t></w:r></w:p></w:tc></w:tr>'
          '<w:tr><w:tc><w:p><w:r><w:t>May</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>12</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
          '</w:body></w:document>',
      'word/media/image1.png': noisy,
      'word/media/icon.png': [1, 2, 3],
    });
    final d = extractDocument('report.docx', docx);
    expect(d.label, 'Word document');
    expect(d.text, contains('## Sales report'));
    expect(d.text, contains('Total was 42 boxes.'));
    expect(d.text, contains('- First point'));
    expect(d.text, contains('| Month | Sales |'));
    expect(d.text, contains('| May | 12 |'));
    expect(d.pictures.map((p) => p.$1), ['image1.png']);
  });

  test('Excel: every sheet as a table with shared strings, numbers and booleans', () {
    const ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
    final xlsx = zipOf({
      'xl/workbook.xml': '<workbook $ns><sheets>'
          '<sheet name="Sales" sheetId="1" r:id="rId1"/><sheet name="Notes" sheetId="2" r:id="rId2"/>'
          '</sheets></workbook>',
      'xl/_rels/workbook.xml.rels':
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Target="worksheets/sheet1.xml"/>'
              '<Relationship Id="rId2" Target="/xl/worksheets/sheet2.xml"/></Relationships>',
      'xl/sharedStrings.xml': '<sst $ns><si><t>Month</t></si><si><t>Total</t></si><si><r><t>Ma</t></r><r><t>y</t></r></si></sst>',
      'xl/worksheets/sheet1.xml': '<worksheet $ns><sheetData>'
          '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
          '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>99.5</v></c></row>'
          '<row r="3"><c r="A3" t="inlineStr"><is><t>June</t></is></c><c r="B3" t="b"><v>1</v></c></row>'
          '</sheetData></worksheet>',
      'xl/worksheets/sheet2.xml': '<worksheet $ns><sheetData/></worksheet>',
    });
    final d = extractDocument('book.xlsx', xlsx);
    expect(d.text, contains('## Sheet: Sales'));
    expect(d.text, contains('| Month | Total |  |'));
    expect(d.text, contains('| May |  | 99.5 |'));
    expect(d.text, contains('| June | TRUE |  |'));
    expect(d.text, contains('## Sheet: Notes\n\n(empty)'));
  });

  test('PowerPoint: slides in order with speaker notes', () {
    const a = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"';
    String slide(String t) => '<p:sld xmlns:p="p" $a><a:p><a:r><a:t>$t</a:t></a:r></a:p></p:sld>';
    final pptx = zipOf({
      'ppt/slides/slide10.xml': slide('Last'),
      'ppt/slides/slide2.xml': slide('Second'),
      'ppt/slides/slide1.xml': slide('Welcome'),
      'ppt/slides/_rels/slide1.xml.rels':
          '<Relationships><Relationship Id="r1" Target="../notesSlides/notesSlide1.xml"/></Relationships>',
      'ppt/notesSlides/notesSlide1.xml': slide('Say hello'),
    });
    final t = extractDocument('deck.pptx', pptx).text;
    expect(t.indexOf('Welcome'), lessThan(t.indexOf('Second')));
    expect(t.indexOf('Second'), lessThan(t.indexOf('Last')));
    expect(t, contains('## Slide 1\nWelcome\nSpeaker notes: Say hello'));
  });

  test('OpenDocument text and spreadsheet', () {
    const ns = 'xmlns:office="o" xmlns:text="t" xmlns:table="tb"';
    final odt = zipOf({
      'content.xml': '<office:document-content $ns><office:body><office:text>'
          '<text:h>Title</text:h><text:p>Hello<text:s text:c="2"/>world</text:p>'
          '</office:text></office:body></office:document-content>',
    });
    expect(extractDocument('a.odt', odt).text, contains('## Title\nHello  world'));
    final ods = zipOf({
      'content.xml': '<office:document-content $ns><office:body><office:spreadsheet>'
          '<table:table table:name="Data"><table:table-row>'
          '<table:table-cell><text:p>x</text:p></table:table-cell>'
          '<table:table-cell table:number-columns-repeated="2"><text:p>y</text:p></table:table-cell>'
          '<table:table-cell table:number-columns-repeated="1000"/>'
          '</table:table-row></table:table></office:spreadsheet></office:body></office:document-content>',
    });
    final t = extractDocument('a.ods', ods).text;
    expect(t, contains('## Sheet: Data'));
    expect(t, contains('| x | y | y |'));
  });

  test('RTF, EPUB and ZIP', () {
    final rtf = Uint8List.fromList(latin1.encode(
        r"{\rtf1\ansi{\fonttbl{\f0 Arial;}}\f0 Caf\'e9 menu\par Tea " r'\u' '8364? 2' r'\par}'));
    expect(extractDocument('m.rtf', rtf).text, 'Café menu\nTea € 2');

    final epub = zipOf({
      'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>',
      'OEBPS/book.opf': '<package><manifest><item id="c2" href="two.xhtml"/><item id="c1" href="one.xhtml"/></manifest>'
          '<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
      'OEBPS/one.xhtml': '<html><body><h1>Chapter 1</h1><p>It was a dark night.</p></body></html>',
      'OEBPS/two.xhtml': '<html><body><h1>Chapter 2</h1><p>Morning came.</p></body></html>',
    });
    final e = extractDocument('b.epub', epub).text;
    expect(e, contains('## Chapter 1'));
    expect(e.indexOf('dark night'), lessThan(e.indexOf('Morning came')));

    final zip = zipOf({'src/main.py': 'print("hi")', 'photo.png': noisy, 'data.bin': [0, 1, 2]});
    final z = extractDocument('code.zip', zip);
    expect(z.text, contains('Files in this ZIP (3)'));
    expect(z.text, contains('<file name="src/main.py">\nprint("hi")'));
    expect(z.pictures, hasLength(1));
  });

  test('old Office files and damaged files get a clear message', () {
    expect(() => extractDocument('old.doc', Uint8List(10)),
        throwsA(isA<DocumentException>().having((e) => e.message, 'm', contains('save it as .docx'))));
    expect(() => extractDocument('bad.xlsx', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<DocumentException>().having((e) => e.message, 'm', contains('damaged'))));
  });

  test('very long documents are cut with a note', () {
    final long = List.filled(30000, '<w:p><w:r><w:t>0123456789</w:t></w:r></w:p>').join();
    final d = extractDocument('big.docx', zipOf({'word/document.xml': '<w:document $w><w:body>$long</w:body></w:document>'}));
    expect(d.cut, isTrue);
    expect(d.text.length, lessThan(maxDocumentChars + 200));
    expect(d.text, endsWith('more characters]'));
  });

  test('attaching a Word file gives the text plus its pictures', () async {
    final docx = zipOf({
      'word/document.xml': '<w:document $w><w:body><w:p><w:r><w:t>Hi</w:t></w:r></w:p></w:body></w:document>',
      'word/media/image1.png': noisy,
    });
    final out = await AttachmentService().fromBytesAll('note.docx', docx);
    expect(out, hasLength(2));
    expect(out.first.kind, AttachmentKind.text);
    expect(out.first.text, '[Word document]\nHi');
    expect(out.first.mimeType, contains('wordprocessingml'));
    expect(out.last.kind, AttachmentKind.image);
    expect(out.last.name, startsWith('note.docx – image1'));
    await expectLater(AttachmentService().fromBytesAll('x.ppt', Uint8List(4)),
        throwsA(isA<AttachmentException>()));
  });
}

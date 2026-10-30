import 'dart:convert';

import 'package:ai_chatbot/data/llm/sse.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<List<int>> chunks(List<String> parts) =>
    Stream.fromIterable(parts.map(utf8.encode));

void main() {
  test('parses events split across chunks', () async {
    final events = await parseSse(chunks([
      'event: content_block_delta\ndata: {"a"',
      ':1}\n\n',
      ': keep-alive comment\n\n',
      'data: line1\ndata: line2\n\n',
      'data: [DONE]\n\n',
    ])).toList();

    expect(events.map((e) => e.event), ['content_block_delta', null, null]);
    expect(events.map((e) => e.data), ['{"a":1}', 'line1\nline2', '[DONE]']);
  });

  test('flushes a trailing event without a blank line', () async {
    final events = await parseSse(chunks(['data: x'])).toList();
    expect(events.single.data, 'x');
  });

  test('handles CRLF line endings', () async {
    final events = await parseSse(chunks(['data: hi\r\n\r\n'])).toList();
    expect(events.single.data, 'hi');
  });
}

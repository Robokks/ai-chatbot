import 'dart:async';
import 'dart:convert';

/// One Server-Sent Event.
class SseEvent {
  const SseEvent(this.event, this.data);
  final String? event;
  final String data;
}

/// Parses a byte stream of `text/event-stream` into events.
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = StringBuffer();
  var hasData = false;

  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (hasData) yield SseEvent(event, data.toString());
      event = null;
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
    }
  }
  if (hasData) yield SseEvent(event, data.toString());
}

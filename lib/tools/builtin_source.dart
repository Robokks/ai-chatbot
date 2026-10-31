import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:math_expressions/math_expressions.dart';

import '../core/device_stats.dart';
import '../core/storage.dart';
import '../core/usage.dart';
import 'tool_source.dart';

/// Tools built into the app: they work on phones without any setup.
class BuiltinToolSource {
  BuiltinToolSource(this.storage, {http.Client? client}) : _client = client ?? http.Client();

  final Storage storage;
  final http.Client _client;

  static const _device = MethodChannel('chatbot/device');

  /// Web tools can't run in the browser build (CORS).
  static bool get webToolsSupported => !kIsWeb;

  List<SourceTool> get tools => [
        if (webToolsSupported) ...[
          const SourceTool(
            name: 'web_search',
            description: 'Search the web (DuckDuckGo). Returns titles, links and snippets. '
                'Use read_web_page to read a result.',
            inputSchema: {
              'type': 'object',
              'properties': {
                'query': {'type': 'string', 'description': 'What to search for'},
              },
              'required': ['query'],
            },
          ),
          const SourceTool(
            name: 'read_web_page',
            description: 'Read a public web page and return its text.',
            inputSchema: {
              'type': 'object',
              'properties': {
                'url': {'type': 'string', 'description': 'http(s) URL'},
              },
              'required': ['url'],
            },
          ),
        ],
        const SourceTool(
          name: 'calculator',
          description: 'Evaluate a math expression exactly, e.g. "(17.5*3)^2/4", "sqrt(2)", "sin(pi/6)".',
          inputSchema: {
            'type': 'object',
            'properties': {
              'expression': {'type': 'string'},
            },
            'required': ['expression'],
          },
        ),
        const SourceTool(
          name: 'date_time',
          description: 'The current local date, time, weekday and time zone.',
          inputSchema: {'type': 'object', 'properties': {}},
        ),
        const SourceTool(
          name: 'device_info',
          description: 'This device\'s battery, memory (RAM) and free storage.',
          inputSchema: {'type': 'object', 'properties': {}},
        ),
        const SourceTool(
          name: 'save_note',
          description: 'Save a note on this device (replaces a note with the same title).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'text': {'type': 'string'},
            },
            'required': ['title', 'text'],
          },
        ),
        const SourceTool(
          name: 'list_notes',
          description: 'List the titles of saved notes.',
          inputSchema: {'type': 'object', 'properties': {}},
        ),
        const SourceTool(
          name: 'read_note',
          description: 'Read a saved note by title.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
            },
            'required': ['title'],
          },
        ),
        const SourceTool(
          name: 'delete_note',
          description: 'Delete a saved note by title.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
            },
            'required': ['title'],
          },
          alwaysAsk: true,
        ),
      ];

  Future<ToolOutput> call(String tool, Map<String, dynamic> a) async {
    try {
      return switch (tool) {
        'web_search' => await webSearch('${a['query'] ?? ''}'),
        'read_web_page' => await readWebPage('${a['url'] ?? ''}'),
        'calculator' => calculate('${a['expression'] ?? ''}'),
        'date_time' => ToolOutput(dateTime(DateTime.now())),
        'device_info' => await deviceInfo(),
        'save_note' => await _saveNote('${a['title'] ?? ''}', '${a['text'] ?? ''}'),
        'list_notes' => ToolOutput(_notes().keys.isEmpty ? 'No notes yet.' : _notes().keys.join('\n')),
        'read_note' => _readNote('${a['title'] ?? ''}'),
        'delete_note' => await _deleteNote('${a['title'] ?? ''}'),
        _ => ToolOutput('Unknown tool "$tool"', isError: true),
      };
    } on ToolError catch (e) {
      return ToolOutput(e.message, isError: true);
    }
  }

  // Web

  static const _ua = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36';

  Future<ToolOutput> webSearch(String query) async {
    if (query.trim().isEmpty) throw ToolError('Give a search query.');
    final res = await _client.post(
      Uri.parse('https://html.duckduckgo.com/html/'),
      headers: {'user-agent': _ua, 'content-type': 'application/x-www-form-urlencoded'},
      body: {'q': query},
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw ToolError('Search failed (status ${res.statusCode}).');
    final results = parseDuckDuckGo(res.body);
    if (results.isEmpty) {
      return const ToolOutput('No results (or DuckDuckGo changed its page format).');
    }
    return ToolOutput([
      for (final (i, r) in results.take(8).indexed) '${i + 1}. ${r.title}\n${r.url}\n${r.snippet}',
    ].join('\n\n'));
  }

  /// Parses DuckDuckGo's HTML results page.
  static List<({String title, String url, String snippet})> parseDuckDuckGo(String body) {
    final doc = html.parse(body);
    final out = <({String title, String url, String snippet})>[];
    for (final r in doc.querySelectorAll('.result')) {
      if (r.classes.contains('result--ad')) continue;
      final a = r.querySelector('a.result__a');
      final href = a?.attributes['href'];
      if (a == null || href == null) continue;
      out.add((
        title: a.text.trim(),
        url: decodeDuckDuckGoLink(href),
        snippet: r.querySelector('.result__snippet')?.text.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '',
      ));
    }
    return out;
  }

  /// "//duckduckgo.com/l/?uddg=https%3A%2F%2Fx.com&rut=…" → "https://x.com".
  static String decodeDuckDuckGoLink(String href) {
    final uri = Uri.tryParse(href.startsWith('//') ? 'https:$href' : href);
    return uri?.queryParameters['uddg'] ?? href;
  }

  Future<ToolOutput> readWebPage(String url) async {
    var uri = Uri.tryParse(url.trim());
    for (var hop = 0; hop < 5; hop++) {
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
        throw ToolError('Only public http(s) addresses can be read.');
      }
      await ensurePublicHost(uri.host);
      final req = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['user-agent'] = _ua
        ..headers['accept'] = 'text/html,text/plain;q=0.9,*/*;q=0.5';
      final res = await http.Response.fromStream(
          await _client.send(req).timeout(const Duration(seconds: 20)));
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
        final next = res.headers['location'];
        if (next == null) break;
        uri = uri.resolve(next);
        continue;
      }
      if (res.statusCode != 200) throw ToolError('The page returned status ${res.statusCode}.');
      final type = res.headers['content-type'] ?? '';
      final text = type.contains('html') ? htmlToText(res.body) : res.body;
      return ToolOutput(clip(text));
    }
    throw ToolError('Too many redirects.');
  }

  /// Refuses local, private and link-local addresses so a page or prompt
  /// can't make the AI probe the user's own network (router, NAS, host).
  static Future<void> ensurePublicHost(String host) async {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower.endsWith('.local') || lower.endsWith('.localhost')) {
      throw ToolError('Local network addresses are blocked.');
    }
    final List<InternetAddress> addresses;
    try {
      addresses = InternetAddress.tryParse(host) != null
          ? [InternetAddress(host)]
          : await InternetAddress.lookup(host);
    } catch (_) {
      throw ToolError('Could not find "$host".');
    }
    if (addresses.isEmpty || addresses.any(isPrivateAddress)) {
      throw ToolError('Local network addresses are blocked.');
    }
  }

  static bool isPrivateAddress(InternetAddress a) {
    if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      return b[0] == 0 ||
          b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) || // carrier-grade NAT
          (b[0] == 169 && b[1] == 254);
    }
    // IPv6 unique-local fc00::/7, and IPv4-mapped addresses.
    if ((b[0] & 0xfe) == 0xfc) return true;
    final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    return mapped && isPrivateAddress(InternetAddress.fromRawAddress(b.sublist(12)));
  }

  static const _skip = {'script', 'style', 'noscript', 'svg', 'iframe', 'template', 'head'};
  static const _blocks = {
    'p', 'div', 'section', 'article', 'header', 'footer', 'main', 'aside', 'nav', 'br', 'tr',
    'table', 'ul', 'ol', 'pre', 'blockquote', 'figure', 'form',
  };

  /// Readable text from HTML: headings marked with #, list items with -.
  static String htmlToText(String source) {
    final doc = html.parse(source);
    final out = StringBuffer();
    final title = doc.querySelector('title')?.text.trim();
    if (title != null && title.isNotEmpty) out.writeln('Title: $title\n');
    void walk(dom.Node n) {
      if (n is dom.Text) {
        out.write(n.text.replaceAll(RegExp(r'\s+'), ' '));
        return;
      }
      if (n is! dom.Element) {
        n.nodes.forEach(walk);
        return;
      }
      final tag = n.localName ?? '';
      if (_skip.contains(tag)) return;
      final heading = RegExp(r'^h([1-6])$').firstMatch(tag);
      if (heading != null) {
        out.write('\n\n${'#' * int.parse(heading[1]!)} ');
      } else if (tag == 'li') {
        out.write('\n- ');
      } else if (_blocks.contains(tag)) {
        out.write('\n');
      }
      n.nodes.forEach(walk);
      if (heading != null || _blocks.contains(tag)) out.write('\n');
    }

    walk(doc.body ?? doc.documentElement!);
    return out
        .toString()
        .split('\n')
        .map((l) => l.trim())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  // Calculator, time, device

  static ToolOutput calculate(String expression) {
    if (expression.trim().isEmpty) throw ToolError('Give an expression.');
    try {
      final exp = GrammarParser().parse(expression.replaceAll('×', '*').replaceAll('÷', '/'));
      final context = ContextModel()
        ..bindVariableName('pi', Number(3.141592653589793))
        ..bindVariableName('e', Number(2.718281828459045));
      final num v = RealEvaluator(context).evaluate(exp);
      if (v.isNaN || v.isInfinite) throw ToolError('The result is not a finite number.');
      final s = v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();
      return ToolOutput('$expression = $s');
    } on ToolError {
      rethrow;
    } catch (_) {
      throw ToolError('Could not understand "$expression".');
    }
  }

  static String dateTime(DateTime now) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '${days[now.weekday - 1]}, ${now.toIso8601String().substring(0, 19).replaceFirst('T', ' ')} '
        '(${now.timeZoneName}, UTC$sign$hh:$mm)';
  }

  Future<ToolOutput> deviceInfo() async {
    final d = await readDeviceStats();
    Map? battery;
    try {
      battery = await _device.invokeMapMethod<String, dynamic>('battery');
    } catch (_) {}
    return ToolOutput([
      if (d.name != null) 'Device: ${d.name}',
      if (battery != null && battery['level'] != null)
        'Battery: ${battery['level']}%${battery['charging'] == true ? ' (charging)' : ''}'
      else
        'Battery: not reported',
      if (d.totalRamMb != null)
        'Memory: ${d.freeRamMb == null ? '' : '${formatBytes(d.freeRamMb! << 20)} free of '}'
            '${formatBytes(d.totalRamMb! << 20)}',
      if (d.freeDiskBytes != null)
        'Storage: ${formatBytes(d.freeDiskBytes!)} free'
            '${d.totalDiskBytes == null ? '' : ' of ${formatBytes(d.totalDiskBytes!)}'}',
    ].join('\n'));
  }

  // Notes

  Map<String, String> _notes() {
    final raw = storage.getSetting('tools.notes');
    return raw == null ? {} : Map<String, String>.from(jsonDecode(raw) as Map);
  }

  Future<void> _writeNotes(Map<String, String> n) => storage.setSetting('tools.notes', jsonEncode(n));

  Future<ToolOutput> _saveNote(String title, String text) async {
    if (title.trim().isEmpty) throw ToolError('A note needs a title.');
    final n = _notes()..[title.trim()] = text;
    await _writeNotes(n);
    return ToolOutput('Saved "${title.trim()}".');
  }

  ToolOutput _readNote(String title) {
    final text = _notes()[title.trim()];
    return text == null ? ToolOutput('No note called "$title".', isError: true) : ToolOutput(text);
  }

  Future<ToolOutput> _deleteNote(String title) async {
    final n = _notes();
    if (n.remove(title.trim()) == null) return ToolOutput('No note called "$title".', isError: true);
    await _writeNotes(n);
    return ToolOutput('Deleted "$title".');
  }
}

class ToolError implements Exception {
  ToolError(this.message);
  final String message;
  @override
  String toString() => message;
}

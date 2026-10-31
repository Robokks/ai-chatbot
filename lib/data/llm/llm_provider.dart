import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'anthropic_provider.dart';
import 'gemini_provider.dart';
import 'openai_provider.dart';

/// A piece of streamed output.
class ChatDelta {
  const ChatDelta({this.text = '', this.reasoning = '', this.notice, this.status});
  final String text;
  final String reasoning;

  /// A non-fatal message to show under the reply (e.g. a refusal).
  final String? notice;

  /// Transient progress shown while waiting for output (e.g. loading a model).
  final String? status;
}

class ChatRequest {
  const ChatRequest({
    required this.model,
    required this.messages,
    this.systemPrompt,
  });
  final String model;
  final List<Message> messages;
  final String? systemPrompt;
}

class LlmException implements Exception {
  LlmException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

abstract class LlmProvider {
  LlmProvider({required this.settings, required this.apiKey, http.Client? client})
      : client = client ?? http.Client();

  final ProviderSettings settings;
  final String apiKey;
  final http.Client client;

  ProviderKind get kind => settings.kind;
  String get baseUrl => settings.baseUrl.replaceAll(RegExp(r'/+$'), '');

  /// Streams the assistant reply for [request].
  Stream<ChatDelta> streamChat(ChatRequest request);

  /// Lists model ids available to this key.
  Future<List<String>> listModels();

  /// Sends a request and throws an [LlmException] for non-2xx responses.
  Future<http.StreamedResponse> send(http.BaseRequest req) async {
    final res = await client.send(req);
    if (res.statusCode >= 300) {
      final body = await res.stream.bytesToString();
      throw LlmException(describeError(res.statusCode, body),
          statusCode: res.statusCode);
    }
    return res;
  }

  static String describeError(int status, String body) {
    String? detail;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        detail = e is Map ? e['message']?.toString() : e?.toString();
        detail ??= j['message']?.toString();
      } else if (j is List && j.isNotEmpty && j.first is Map) {
        detail = (j.first['error'] as Map?)?['message']?.toString();
      }
    } catch (_) {
      detail = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    }
    final hint = switch (status) {
      401 || 403 => 'Check your API key in Settings.',
      404 => 'The model or endpoint was not found.',
      429 => 'Rate limited or out of credits. Try again shortly.',
      >= 500 => 'The provider had a server error. Try again.',
      _ => null,
    };
    return [
      'Error $status',
      if (detail != null && detail.isNotEmpty) detail,
      ?hint,
    ].join(' · ');
  }

  static LlmProvider create(ProviderSettings settings, String apiKey,
      {http.Client? client}) {
    return switch (settings.kind.style) {
      ApiStyle.anthropic =>
        AnthropicProvider(settings: settings, apiKey: apiKey, client: client),
      ApiStyle.openai =>
        OpenAiProvider(settings: settings, apiKey: apiKey, client: client),
      ApiStyle.gemini =>
        GeminiProvider(settings: settings, apiKey: apiKey, client: client),
      ApiStyle.local => throw UnsupportedError(
          'On-device models are created with LocalProvider, not LlmProvider.create'),
    };
  }
}

/// Inlines text attachments (and PDFs, for providers without native PDF
/// support) as fenced blocks ahead of the user's own text.
String inlineTextAttachments(Message m, {required bool includePdf}) {
  final parts = <String>[];
  for (final a in m.attachments) {
    final isText = a.kind == AttachmentKind.text;
    final isPdfText = a.kind == AttachmentKind.pdf && includePdf;
    if ((isText || isPdfText) && a.text != null) {
      parts.add('<file name="${a.name}">\n${a.text}\n</file>');
    }
  }
  if (m.text.isNotEmpty) parts.add(m.text);
  return parts.join('\n\n');
}

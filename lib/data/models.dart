import 'dart:typed_data';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

enum AttachmentKind { image, pdf, text }

/// A file attached to a user message. [bytes] holds the raw content for
/// images and PDFs; [text] holds decoded/extracted text for text files and
/// PDFs (used by providers without native PDF support).
class Attachment {
  Attachment({
    String? id,
    required this.name,
    required this.mimeType,
    required this.kind,
    required this.size,
    this.bytes,
    this.text,
  }) : id = id ?? newId();

  final String id;
  final String name;
  final String mimeType;
  final AttachmentKind kind;
  final int size;
  Uint8List? bytes;
  String? text;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mimeType': mimeType,
        'kind': kind.name,
        'size': size,
        if (text != null) 'text': text,
      };

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        id: j['id'] as String,
        name: j['name'] as String,
        mimeType: j['mimeType'] as String,
        kind: AttachmentKind.values.byName(j['kind'] as String),
        size: j['size'] as int,
        text: j['text'] as String?,
      );
}

/// Token counts and timing for one assistant reply.
class UsageStats {
  UsageStats({
    this.inputTokens,
    this.outputTokens,
    this.cachedTokens,
    this.firstTokenMs,
    this.durationMs,
  });

  int? inputTokens;
  int? outputTokens;

  /// Prompt tokens served from the provider's cache (cheaper), if reported.
  int? cachedTokens;

  /// Time from sending to the first streamed word.
  int? firstTokenMs;

  /// Time from sending to the end of the reply.
  int? durationMs;

  /// Output speed while generating, excluding the wait for the first word.
  double? get tokensPerSecond {
    final out = outputTokens, total = durationMs, first = firstTokenMs ?? 0;
    if (out == null || out == 0 || total == null || total - first <= 0) return null;
    return out / ((total - first) / 1000);
  }

  /// Copies non-null token counts from [other] (providers report in parts).
  void merge(UsageStats other) {
    inputTokens = other.inputTokens ?? inputTokens;
    outputTokens = other.outputTokens ?? outputTokens;
    cachedTokens = other.cachedTokens ?? cachedTokens;
  }

  Map<String, dynamic> toJson() => {
        if (inputTokens != null) 'in': inputTokens,
        if (outputTokens != null) 'out': outputTokens,
        if (cachedTokens != null) 'cached': cachedTokens,
        if (firstTokenMs != null) 'firstMs': firstTokenMs,
        if (durationMs != null) 'ms': durationMs,
      };

  factory UsageStats.fromJson(Map<String, dynamic> j) => UsageStats(
        inputTokens: j['in'] as int?,
        outputTokens: j['out'] as int?,
        cachedTokens: j['cached'] as int?,
        firstTokenMs: j['firstMs'] as int?,
        durationMs: j['ms'] as int?,
      );
}

enum Role { user, assistant, tool }

/// A tool the AI may call, from MCP, UTCP, A2A or a CLI program.
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.sourceId,
    required this.sourceLabel,
    this.needsApproval = false,
  });

  /// Name shown to the model: unique, `[A-Za-z0-9_-]{1,64}`.
  final String name;
  final String description;

  /// JSON Schema (object) for the arguments.
  final Map<String, dynamic> inputSchema;
  final String sourceId;

  /// e.g. "MCP · Old phone".
  final String sourceLabel;

  /// Ask the user before each run (always true for CLI tools).
  final bool needsApproval;
}

/// A tool call made by the AI.
class ToolCall {
  ToolCall({required this.id, required this.name, required this.arguments});

  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'arguments': arguments};

  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
        id: j['id'] as String,
        name: j['name'] as String,
        arguments: Map<String, dynamic>.from(j['arguments'] as Map? ?? const {}),
      );
}

/// What running a [ToolCall] returned.
class ToolResult {
  ToolResult({
    required this.callId,
    required this.name,
    required this.text,
    this.isError = false,
    this.imageIds = const [],
  });

  final String callId;
  final String name;
  final String text;
  final bool isError;

  /// Gallery pictures made by the tool (shown in the chat only).
  final List<String> imageIds;

  Map<String, dynamic> toJson() => {
        'callId': callId,
        'name': name,
        'text': text,
        if (isError) 'isError': true,
        if (imageIds.isNotEmpty) 'imageIds': imageIds,
      };

  factory ToolResult.fromJson(Map<String, dynamic> j) => ToolResult(
        callId: j['callId'] as String,
        name: j['name'] as String,
        text: j['text'] as String,
        isError: j['isError'] as bool? ?? false,
        imageIds: [for (final i in j['imageIds'] as List? ?? const []) '$i'],
      );
}

class Message {
  Message({
    String? id,
    required this.role,
    this.text = '',
    this.reasoning = '',
    List<Attachment>? attachments,
    this.error,
    this.model,
    this.provider,
    this.usage,
    List<ToolCall>? toolCalls,
    List<ToolResult>? toolResults,
    this.providerBlocks,
    DateTime? createdAt,
  })  : id = id ?? newId(),
        toolCalls = toolCalls ?? [],
        toolResults = toolResults ?? [],
        attachments = attachments ?? [],
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final Role role;
  String text;
  String reasoning;
  final List<Attachment> attachments;
  String? error;
  String? model;

  /// Provider that wrote this reply (for usage totals and pricing).
  ProviderKind? provider;
  UsageStats? usage;

  /// Tools the assistant asked to run in this turn.
  final List<ToolCall> toolCalls;

  /// Results of those calls (on [Role.tool] messages).
  final List<ToolResult> toolResults;

  /// The provider's raw content for this turn (e.g. Claude thinking blocks
  /// with signatures, Gemini thought signatures), replayed unchanged on the
  /// next request when tools are involved.
  List<Map<String, dynamic>>? providerBlocks;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
        if (error != null) 'error': error,
        if (model != null) 'model': model,
        if (provider != null) 'provider': provider!.name,
        if (usage != null) 'usage': usage!.toJson(),
        if (toolCalls.isNotEmpty) 'toolCalls': [for (final c in toolCalls) c.toJson()],
        if (toolResults.isNotEmpty) 'toolResults': [for (final r in toolResults) r.toJson()],
        if (providerBlocks != null) 'providerBlocks': providerBlocks,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'] as String,
        role: Role.values.byName(j['role'] as String),
        text: j['text'] as String? ?? '',
        reasoning: j['reasoning'] as String? ?? '',
        attachments: (j['attachments'] as List? ?? [])
            .map((a) => Attachment.fromJson(Map<String, dynamic>.from(a)))
            .toList(),
        error: j['error'] as String?,
        model: j['model'] as String?,
        provider: ProviderKind.values.asNameMap()[j['provider']],
        usage: j['usage'] == null
            ? null
            : UsageStats.fromJson(Map<String, dynamic>.from(j['usage'] as Map)),
        toolCalls: [
          for (final c in j['toolCalls'] as List? ?? const [])
            ToolCall.fromJson(Map<String, dynamic>.from(c as Map)),
        ],
        toolResults: [
          for (final r in j['toolResults'] as List? ?? const [])
            ToolResult.fromJson(Map<String, dynamic>.from(r as Map)),
        ],
        providerBlocks: (j['providerBlocks'] as List?)
            ?.map((b) => Map<String, dynamic>.from(b as Map))
            .toList(),
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

class Conversation {
  Conversation({
    String? id,
    this.title = 'New chat',
    List<Message>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? newId(),
        messages = messages ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  final List<Message> messages;
  final DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'messages': messages.map((m) => m.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        title: j['title'] as String,
        messages: (j['messages'] as List)
            .map((m) => Message.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );
}

/// API style a provider speaks.
enum ApiStyle { anthropic, openai, gemini, local }

/// Supported providers. Most non-Anthropic/Google vendors expose an
/// OpenAI-compatible Chat Completions endpoint.
enum ProviderKind {
  anthropic(
    label: 'Claude',
    vendor: 'Anthropic',
    style: ApiStyle.anthropic,
    baseUrl: 'https://api.anthropic.com/v1',
    models: ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-1'],
    keyUrl: 'https://console.anthropic.com/settings/keys',
    images: true,
    pdf: true,
  ),
  openai(
    label: 'ChatGPT',
    vendor: 'OpenAI',
    style: ApiStyle.openai,
    baseUrl: 'https://api.openai.com/v1',
    models: ['gpt-5', 'gpt-5-mini', 'gpt-4.1', 'gpt-4o'],
    keyUrl: 'https://platform.openai.com/api-keys',
    images: true,
    pdf: true,
  ),
  deepseek(
    label: 'DeepSeek',
    vendor: 'DeepSeek',
    style: ApiStyle.openai,
    baseUrl: 'https://api.deepseek.com/v1',
    models: ['deepseek-chat', 'deepseek-reasoner'],
    keyUrl: 'https://platform.deepseek.com/api_keys',
    images: false,
    pdf: false,
  ),
  gemini(
    label: 'Gemini',
    vendor: 'Google',
    style: ApiStyle.gemini,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    models: ['gemini-2.5-pro', 'gemini-2.5-flash'],
    keyUrl: 'https://aistudio.google.com/apikey',
    images: true,
    pdf: true,
  ),
  openrouter(
    label: 'OpenRouter',
    vendor: 'OpenRouter',
    style: ApiStyle.openai,
    baseUrl: 'https://openrouter.ai/api/v1',
    models: ['anthropic/claude-sonnet-5-5', 'openai/gpt-5', 'deepseek/deepseek-chat'],
    keyUrl: 'https://openrouter.ai/keys',
    images: true,
    pdf: false,
  ),
  groq(
    label: 'Groq',
    vendor: 'Groq',
    style: ApiStyle.openai,
    baseUrl: 'https://api.groq.com/openai/v1',
    models: ['llama-3.3-70b-versatile'],
    keyUrl: 'https://console.groq.com/keys',
    images: false,
    pdf: false,
  ),
  local(
    label: 'On-device',
    vendor: 'Offline',
    style: ApiStyle.local,
    baseUrl: '',
    models: [],
    keyUrl: '',
    images: false,
    pdf: false,
  ),
  network(
    label: 'Home server',
    vendor: 'Another device',
    style: ApiStyle.openai,
    baseUrl: '',
    models: [],
    keyUrl: '',
    images: true,
    pdf: false,
  ),
  custom(
    label: 'Custom',
    vendor: 'OpenAI-compatible',
    style: ApiStyle.openai,
    baseUrl: 'http://localhost:11434/v1',
    models: ['llama3.2'],
    keyUrl: '',
    images: true,
    pdf: false,
  );

  const ProviderKind({
    required this.label,
    required this.vendor,
    required this.style,
    required this.baseUrl,
    required this.models,
    required this.keyUrl,
    required this.images,
    required this.pdf,
  });

  final String label;
  final String vendor;
  final ApiStyle style;
  final String baseUrl;
  final List<String> models;
  final String keyUrl;

  /// Whether the provider accepts image input (model permitting).
  final bool images;

  /// Whether the provider accepts PDFs natively; otherwise extracted text is sent.
  final bool pdf;
}

/// User-editable per-provider settings (the API key lives in secure storage).
class ProviderSettings {
  ProviderSettings({required this.kind, String? baseUrl, List<String>? models})
      : baseUrl = baseUrl ?? kind.baseUrl,
        models = models ?? List.of(kind.models);

  final ProviderKind kind;
  String baseUrl;
  List<String> models;

  Map<String, dynamic> toJson() => {'baseUrl': baseUrl, 'models': models};

  factory ProviderSettings.fromJson(ProviderKind kind, Map<String, dynamic> j) =>
      ProviderSettings(
        kind: kind,
        baseUrl: j['baseUrl'] as String?,
        models: (j['models'] as List?)?.cast<String>(),
      );
}

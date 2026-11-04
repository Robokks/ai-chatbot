import '../models.dart';

/// Owner supplied capabilities. Null means unknown, never inferred from an ID.
class ModelOptions {
  ModelOptions({
    this.enabled = true,
    this.vision,
    this.tools,
    this.contextTokens,
  });
  bool enabled;
  bool? vision, tools;
  int? contextTokens;
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'vision': vision,
    'tools': tools,
    'context': contextTokens,
  };
  factory ModelOptions.fromJson(Map<String, dynamic> j) => ModelOptions(
    enabled: j['enabled'] ?? true,
    vision: j['vision'],
    tools: j['tools'],
    contextTokens: j['context'],
  );
}

class QuotaPolicy {
  QuotaPolicy({this.requests, this.tokens, this.windowSeconds = 86400});
  int? requests, tokens;
  int windowSeconds;
  bool get limited => requests != null || tokens != null;
  void validate() {
    if (windowSeconds < 60 ||
        windowSeconds > 31536000 ||
        (requests != null && requests! < 1) ||
        (tokens != null && tokens! < 1)) {
      throw const FormatException(
        'Limits must be positive; reset windows must be between one minute and one year.',
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'requests': requests,
    'tokens': tokens,
    'windowSeconds': windowSeconds,
  };
  factory QuotaPolicy.fromJson(Map<String, dynamic> j) => QuotaPolicy(
    requests: j['requests'],
    tokens: j['tokens'],
    windowSeconds: j['windowSeconds'] ?? 86400,
  );
}

class QuotaWindow {
  QuotaWindow({
    required this.start,
    required this.seconds,
    this.requests = 0,
    this.tokens = 0,
    this.unknown = 0,
  });
  final int start, seconds;
  int requests, tokens, unknown;
  Map<String, dynamic> toJson() => {
    'start': start,
    'seconds': seconds,
    'requests': requests,
    'tokens': tokens,
    'unknown': unknown,
  };
  factory QuotaWindow.fromJson(Map<String, dynamic> j) => QuotaWindow(
    start: j['start'],
    seconds: j['seconds'],
    requests: j['requests'],
    tokens: j['tokens'],
    unknown: j['unknown'] ?? 0,
  );
}

class SourcePreset {
  const SourcePreset(
    this.name,
    this.kind,
    this.baseUrl, {
    this.accountRequired = false,
  });
  final String name, baseUrl;
  final ProviderKind kind;
  final bool accountRequired;
  String urlFor(String account) {
    if (!accountRequired) return baseUrl;
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(account)) {
      throw const FormatException(
        'Enter the Cloudflare account ID from your dashboard.',
      );
    }
    return 'https://api.cloudflare.com/client/v4/accounts/$account/ai/v1';
  }

  // Endpoints only: no model capabilities or account free allowances are assumed.
  static const all = [
    SourcePreset('Custom / FreeLLMAPI', ProviderKind.custom, ''),
    SourcePreset(
      'Google AI Studio',
      ProviderKind.gemini,
      'https://generativelanguage.googleapis.com/v1beta',
    ),
    SourcePreset('Groq', ProviderKind.groq, 'https://api.groq.com/openai/v1'),
    SourcePreset(
      'NVIDIA NIM',
      ProviderKind.custom,
      'https://integrate.api.nvidia.com/v1',
    ),
    SourcePreset(
      'OpenRouter',
      ProviderKind.openrouter,
      'https://openrouter.ai/api/v1',
    ),
    SourcePreset(
      'Cloudflare Workers AI',
      ProviderKind.custom,
      '',
      accountRequired: true,
    ),
  ];
}

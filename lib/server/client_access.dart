import 'dart:convert';

import 'openai_bridge.dart';

/// Built-in model-facing web names and Main's MCP names describe the same tool.
String canonicalToolName(String name) => switch (name) {
  'phone_web_search' => 'web_search',
  'phone_read_web_page' => 'read_web_page',
  _ => name,
};

/// Main's saved rules. Null allowlists/limits mean unrestricted, empty lists deny.
class ClientAccess {
  ClientAccess({
    this.approved = true,
    this.blocked = false,
    this.expires,
    this.models,
    this.services,
    this.tools,
    this.requestsPerDay,
    this.tokensPerDay,
  });

  bool approved;
  bool blocked;
  DateTime? expires;
  Set<String>? models;
  Set<String>? services;
  Set<String>? tools;
  int? requestsPerDay;
  int? tokensPerDay;

  void check({
    required bool stopped,
    String? model,
    String? service,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    String? problem;
    if (stopped) {
      problem = 'Main has stopped all access';
    } else if (blocked) {
      problem = 'This PC is blocked';
    } else if (!approved) {
      problem = 'This PC is waiting for approval';
    } else if (expires != null && !current.isBefore(expires!)) {
      problem = 'Access has expired';
    } else if (model != null && models != null && !models!.contains(model)) {
      problem = 'This model is not allowed';
    } else if (service != null &&
        services != null &&
        !services!.contains(service)) {
      problem = 'This service is not allowed';
    }
    if (problem != null) {
      throw BridgeException(
        '$problem. Ask Main for more access.',
        status: 403,
        code: 'access_denied',
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'approved': approved,
    'blocked': blocked,
    if (expires != null) 'expires': expires!.toIso8601String(),
    if (models != null) 'models': models!.toList(),
    if (services != null) 'services': services!.toList(),
    if (tools != null) 'tools': tools!.toList(),
    if (requestsPerDay != null) 'requestsPerDay': requestsPerDay,
    if (tokensPerDay != null) 'tokensPerDay': tokensPerDay,
  };

  factory ClientAccess.fromJson(Map<String, dynamic> j) => ClientAccess(
    approved: j['approved'] as bool? ?? true,
    blocked: j['blocked'] as bool? ?? false,
    expires: j['expires'] == null
        ? null
        : DateTime.parse(j['expires'] as String),
    models: j['models'] == null ? null : Set<String>.from(j['models'] as List),
    services: j['services'] == null
        ? null
        : Set<String>.from(j['services'] as List),
    tools: j['tools'] == null ? null : Set<String>.from(j['tools'] as List),
    requestsPerDay: j['requestsPerDay'] as int?,
    tokensPerDay: j['tokensPerDay'] as int?,
  );
}

/// Daily counters persist with the paired-device record, including reservations.
class ClientUsage {
  ClientUsage({this.day = '', this.requests = 0, this.tokens = 0});
  String day;
  int requests;
  int tokens;
  int _active = 0;
  bool get hasActiveModelRequest => _active > 0;

  static String dayFor(DateTime now) => '${now.year}-${now.month}-${now.day}';
  void refresh([DateTime? now]) {
    final today = dayFor(now ?? DateTime.now());
    if (day != today) {
      day = today;
      requests = 0;
      tokens = 0;
    }
  }

  /// Reserve the entire remaining token allowance to prevent concurrent overspend.
  /// Unknown provider usage keeps the reservation charged (never grants free runs).
  ClientReservation reserve(
    ClientAccess access, {
    Map<String, dynamic>? input,
    DateTime? now,
  }) {
    refresh(now);
    if (access.requestsPerDay != null && requests >= access.requestsPerDay!) {
      throw BridgeException(
        'Daily request limit reached. Ask Main for more access.',
        status: 429,
        code: 'quota_exceeded',
      );
    }
    if (access.tokensPerDay != null && input != null && _active > 0) {
      throw BridgeException(
        'A request is already using this PC token allowance. Try again when it finishes.',
        status: 429,
        code: 'quota_busy',
      );
    }
    final previous = tokens;
    int? maximum;
    if (access.tokensPerDay != null && input != null) {
      final inputAllowance = utf8.encode(jsonEncode(input)).length + 8192;
      maximum = access.tokensPerDay! - tokens - inputAllowance;
      if (maximum <= 0) {
        throw BridgeException(
          'Not enough daily tokens for this request. Ask Main for more access.',
          status: 429,
          code: 'quota_exceeded',
        );
      }
      tokens = access.tokensPerDay!;
    }
    requests++;
    if (input != null) _active++;
    return ClientReservation(this, day, previous, maximum, input != null);
  }

  Map<String, dynamic> toJson() => {
    'day': day,
    'requests': requests,
    'tokens': tokens,
  };
  factory ClientUsage.fromJson(Map<String, dynamic> j) => ClientUsage(
    day: j['day'] as String? ?? '',
    requests: j['requests'] as int? ?? 0,
    tokens: j['tokens'] as int? ?? 0,
  );
}

class ClientReservation {
  ClientReservation(
    this.usage,
    this.day,
    this.previous,
    this._maximum,
    this.active,
  );
  final ClientUsage usage;
  final String day;
  final int previous;
  final int? _maximum;
  final List<ClientReservation> parents = [];
  int? get maxOutputTokens {
    final values = [
      _maximum,
      ...parents.map((p) => p.maxOutputTokens),
    ].whereType<int>().toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a < b ? a : b);
  }

  final bool active;
  bool _settled = false;

  void cancelBeforeRun() {
    if (_settled) return;
    _settled = true;
    for (final parent in parents) {
      parent.cancelBeforeRun();
    }
    if (active) usage._active--;
    if (usage.day == day) {
      usage.requests--;
      if (_maximum != null) usage.tokens = previous;
    }
  }

  void settle({int? inputTokens, int? outputTokens}) {
    if (_settled) return;
    _settled = true;
    for (final parent in parents) {
      parent.settle(inputTokens: inputTokens, outputTokens: outputTokens);
    }
    if (active) usage._active--;
    if (usage.day != day) return;
    if (inputTokens != null && outputTokens != null) {
      final actual =
          inputTokens.clamp(0, 1 << 50) + outputTokens.clamp(0, 1 << 50);
      if (_maximum != null) {
        usage.tokens = previous + actual;
      } else {
        usage.tokens += actual;
      }
    }
  }
}

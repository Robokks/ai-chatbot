import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/storage.dart';

/// Request metadata only. Never stores prompts, responses, keys or tool arguments.
class LabRequestEvent {
  LabRequestEvent({
    required this.deviceId,
    required this.device,
    required this.model,
    required this.status,
    DateTime? time,
    this.inputTokens,
    this.outputTokens,
    this.durationMs,
    this.firstTokenMs,
    this.kind = 'model',
  }) : time = time ?? DateTime.now();
  final String deviceId, device, model, status, kind;
  final DateTime time;
  final int? inputTokens, outputTokens, durationMs, firstTokenMs;
  Map<String, dynamic> toJson() => {
    'id': deviceId,
    'pc': device,
    'model': model,
    'status': status,
    'kind': kind,
    'time': time.toUtc().toIso8601String(),
    'input': inputTokens,
    'output': outputTokens,
    'duration': durationMs,
    'first': firstTokenMs,
  };
  factory LabRequestEvent.fromJson(Map<String, dynamic> j) => LabRequestEvent(
    deviceId: j['id'] as String,
    device: j['pc'] as String,
    model: j['model'] as String,
    status: j['status'] as String,
    kind: j['kind'] as String? ?? 'model',
    time: DateTime.parse(j['time'] as String),
    inputTokens: j['input'] as int?,
    outputTokens: j['output'] as int?,
    durationMs: j['duration'] as int?,
    firstTokenMs: j['first'] as int?,
  );
}

class LabSummary {
  LabSummary(this.events);
  final List<LabRequestEvent> events;
  int get requests => events.length;
  int get successes => events.where((e) => e.status == 'ok').length;
  int get cancelled => events.where((e) => e.status == 'cancelled').length;
  int get failures => requests - successes - cancelled;
  int? _sum(int? Function(LabRequestEvent) field) {
    final values = events.map(field).whereType<int>();
    return values.isEmpty ? null : values.fold<int>(0, (a, b) => a + b);
  }

  double? _average(int? Function(LabRequestEvent) field) {
    final values = events.map(field).whereType<int>();
    return values.isEmpty
        ? null
        : values.reduce((a, b) => a + b) / values.length;
  }

  int? get inputTokens => _sum((e) => e.inputTokens);
  int? get outputTokens => _sum((e) => e.outputTokens);
  int get inputSamples => events.where((e) => e.inputTokens != null).length;
  int get outputSamples => events.where((e) => e.outputTokens != null).length;
  double? get latencyMs => _average((e) => e.durationMs);
  double? get firstTokenMs => _average((e) => e.firstTokenMs);
  Map<String, LabSummary> by(String Function(LabRequestEvent) key) {
    final groups = <String, List<LabRequestEvent>>{};
    for (final event in events) {
      (groups[key(event)] ??= []).add(event);
    }
    return groups.map((key, value) => MapEntry(key, LabSummary(value)));
  }
}

/// Exact rolling windows over a bounded, persisted metadata history.
/// A visible retention warning prevents silently presenting capped data as complete.
class LabAnalytics extends ChangeNotifier {
  LabAnalytics(
    this.storage, {
    DateTime Function()? clock,
    this.maxEvents = 30000,
  }) : clock = clock ?? DateTime.now {
    _load();
  }
  final Storage storage;
  final DateTime Function() clock;
  final int maxEvents;
  static const storageKey = 'lab.analytics.v1';
  final _events = <LabRequestEvent>[];
  Timer? _timer;
  Future<void>? _saving;
  DateTime? truncatedBefore;
  List<LabRequestEvent> get recent =>
      _events.reversed.take(300).toList(growable: false);
  void _load() {
    try {
      final raw = storage.getSetting(storageKey);
      if (raw == null) {
        return;
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      truncatedBefore = DateTime.tryParse(
        json['truncatedBefore'] as String? ?? '',
      );
      for (final row in json['events'] as List) {
        try {
          _events.add(
            LabRequestEvent.fromJson(Map<String, dynamic>.from(row as Map)),
          );
        } catch (_) {
          /* Ignore corrupt rows. */
        }
      }
      _trim();
    } catch (_) {
      /* Corrupt analytics must never prevent the app starting. */
    }
  }

  void _trim() {
    final cutoff = clock().subtract(const Duration(days: 30));
    _events.removeWhere((e) => e.time.isBefore(cutoff));
    _events.sort((a, b) => a.time.compareTo(b.time));
    if (_events.length > maxEvents) {
      final removed = _events.length - maxEvents;
      truncatedBefore = _events[removed - 1].time;
      _events.removeRange(0, removed);
    }
  }

  Future<void> record(LabRequestEvent event) async {
    _events.add(event);
    _trim();
    notifyListeners();
    _timer ??= Timer(const Duration(milliseconds: 250), () {
      _timer = null;
      unawaited(flush().catchError((Object _) {}));
    });
  }

  LabSummary summary(
    Duration range, {
    String? deviceId,
    String? model,
    DateTime? now,
  }) {
    final end = now ?? clock();
    final start = end.subtract(range);
    return LabSummary(
      _events
          .where(
            (e) =>
                e.kind == 'model' &&
                !e.time.isBefore(start) &&
                !e.time.isAfter(end) &&
                (deviceId == null || e.deviceId == deviceId) &&
                (model == null || e.model == model),
          )
          .toList(growable: false),
    );
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _trim();
    final value = jsonEncode({
      'events': _events.map((e) => e.toJson()).toList(),
      'truncatedBefore': truncatedBefore?.toIso8601String(),
    });
    _saving = (_saving ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) => storage.setSetting(storageKey, value));
    return _saving!;
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(flush().catchError((Object _) {}));
    super.dispose();
  }
}

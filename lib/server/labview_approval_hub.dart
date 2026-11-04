import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/storage.dart';
import '../tools/tool_source.dart';

class LabviewApproval {
  LabviewApproval(this.device, this.tool, this.arguments);
  final String device;
  final String tool;
  final Map<String, dynamic> arguments;
  final Completer<bool> _answer = Completer<bool>();
  void decide(bool allow) {
    if (!_answer.isCompleted) _answer.complete(allow);
  }
}

/// Explicit approval for every remote LabVIEW call; no blanket trust setting.
class LabviewApprovalHub extends ChangeNotifier {
  LabviewApprovalHub({this.timeout = const Duration(minutes: 2)});
  static final _instances = Expando<LabviewApprovalHub>();
  static LabviewApprovalHub forStorage(Storage storage) =>
      _instances[storage] ??= LabviewApprovalHub();
  final Duration timeout;
  final List<LabviewApproval> pending = [];
  bool _disposed = false;
  void answer(LabviewApproval item, bool allow) => item.decide(allow);
  void denyAll() {
    for (final item in List.of(pending)) {
      item.decide(false);
    }
  }

  Future<ToolOutput> run({
    required String device,
    required String tool,
    required Map<String, dynamic> arguments,
    required Future<ToolOutput> Function() execute,
    Future<void>? cancel,
  }) async {
    if (_disposed) {
      return const ToolOutput('LabVIEW sharing stopped.', isError: true);
    }
    final item = LabviewApproval(device, tool, Map.unmodifiable(arguments));
    var cancelled = false;
    cancel?.then((_) {
      cancelled = true;
      item.decide(false);
    });
    pending.add(item);
    notifyListeners();
    final allowed = await item._answer.future.timeout(
      timeout,
      onTimeout: () => false,
    );
    pending.remove(item);
    if (!_disposed) notifyListeners();
    if (!allowed || cancelled || _disposed) {
      return const ToolOutput(
        'LabVIEW run was denied, cancelled or approval expired.',
        isError: true,
      );
    }
    // Transport cancellation cannot undo an instrument action already accepted.
    final result = await execute();
    return cancelled
        ? const ToolOutput(
            'Access revoked during the LabVIEW call. An action already accepted by DynasBrain may still complete.',
            isError: true,
          )
        : result;
  }

  @override
  void dispose() {
    _disposed = true;
    denyAll();
    super.dispose();
  }
}

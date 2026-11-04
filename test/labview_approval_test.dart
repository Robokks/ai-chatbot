import 'dart:async';

import 'package:ai_chatbot/server/labview_approval_hub.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no tool runs before Main approves exactly one request', () async {
    final hub = LabviewApprovalHub();
    var calls = 0;
    final result = hub.run(
      device: 'PC',
      tool: 'inspect',
      arguments: {},
      execute: () async {
        calls++;
        return const ToolOutput('ok');
      },
    );
    expect(calls, 0);
    expect(hub.pending.single.device, 'PC');
    hub.answer(hub.pending.single, true);
    expect((await result).text, 'ok');
    expect(calls, 1);
    expect(hub.pending, isEmpty);
    final denied = hub.run(
      device: 'PC',
      tool: 'inspect',
      arguments: {},
      execute: () async {
        calls++;
        return const ToolOutput('bad');
      },
    );
    hub.denyAll();
    expect((await denied).isError, isTrue);
    expect(calls, 1);
    hub.dispose();
  });
  test(
    'expiry and access revocation cannot launch a waiting LabVIEW action',
    () async {
      final hub = LabviewApprovalHub(timeout: const Duration(milliseconds: 10));
      var calls = 0;
      Future<ToolOutput> execute() async {
        calls++;
        return const ToolOutput('bad');
      }

      expect(
        (await hub.run(
          device: 'PC',
          tool: 'write',
          arguments: {},
          execute: execute,
        )).isError,
        isTrue,
      );
      final cancel = Completer<void>();
      final pending = hub.run(
        device: 'PC',
        tool: 'write',
        arguments: {},
        execute: execute,
        cancel: cancel.future,
      );
      cancel.complete();
      expect((await pending).isError, isTrue);
      expect(calls, 0);
      expect(hub.pending, isEmpty);
      hub.dispose();
    },
  );
}

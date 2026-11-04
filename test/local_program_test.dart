import 'dart:io';
import 'package:ai_chatbot/tools/cli_source.dart';
import 'package:ai_chatbot/tools/local_program.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('script text is never placed in process arguments', () {
    const code = r"print('a b; $(not-a-command)')";
    for (final program in [LocalProgram.python, LocalProgram.node, LocalProgram.powershell, LocalProgram.cmd]) {
      final invocation = localInvocation(program, {'code': code, 'cwd': r'C:\lab'}, windows: true);
      expect(invocation.args.any((a) => a.contains(code)), isFalse);
      expect(invocation.input, contains(code));
      expect(invocation.cwd, r'C:\lab');
    }
  });
  test(r'Git arguments remain literal inside PowerShell, including $(...)', () {
    final invocation = localInvocation(LocalProgram.git,
      {'args': ['status', r"a'b $(Remove-Item x)"]}, windows: true);
    expect(invocation.executable, 'powershell');
    expect(invocation.input, contains(r"'a''b $(Remove-Item x)'"));
    expect(invocation.args, ['-NoProfile', '-NonInteractive', '-Command', '-']);
    expect(() => localInvocation(LocalProgram.git, {'args': [1]}, windows: true), throwsFormatException);
  });
  test('Python tool is ask-first and its approval preview includes code and working folder', () async {
    final source = CliToolSource(ToolSourceConfig(id: 'p', type: ToolSourceType.cli,
      name: 'Python', url: LocalProgram.python.executable,
      askBeforeRun: false, variables: {'localProgram': 'python'}), null);
    final tools = await source.discover();
    expect(tools.single.alwaysAsk, isTrue, reason: 'config must not bypass command confirmation');
    expect(source.describe({'code': 'print(42)', 'cwd': '/lab'}), contains('/lab\nPython:\nprint(42)'));
    final result = await source.call('run', {'code': 'print(42)', 'cwd': Directory.systemTemp.path});
    expect(result.isError, isFalse, reason: result.text);
    expect(result.text, '42');
  });
  test('an injected launcher sees only fixed words and receives code through stdin', () async {
    List<String>? passed;
    final source = CliToolSource(ToolSourceConfig(id: 'n', type: ToolSourceType.cli,
      name: 'Node', url: 'node', variables: {'localProgram': 'node'}), null,
      launcher: (exe, args, cwd) { passed = args; return Process.start('sh', ['-c', 'cat']); });
    const code = r'console.log("literal $(thing)");';
    final result = await source.call('run', {'code': code, 'cwd': Directory.systemTemp.path});
    expect(passed, ['-']);
    expect(result.text, code);
  });
}

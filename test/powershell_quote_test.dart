import 'package:ai_chatbot/tools/cli_runner.dart';
import 'package:ai_chatbot/tools/tool_source.dart';
import 'package:ai_chatbot/tools/utcp_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(r'powershellQuote leaves $(...) literal and escapes single quotes', () {
    expect(powershellQuote(r"a'b $(rm x)"), r"'a''b $(rm x)'");
    expect(powershellQuote(''), "''");
  });
  test('Windows UTCP approval preview uses PowerShell literal quoting', () async {
    final source = UtcpToolSource(
      ToolSourceConfig(id: 'u', type: ToolSourceType.utcp, name: 'u', url: 'https://example.com/manual'),
      null, allowedPrograms: {'echo'}, windows: true,
      client: MockClient((_) async => http.Response(
        r'''{"tools":[{"name":"echo","description":"Echo","inputs":{"type":"object"},"tool_call_template":{"call_template_type":"cli","commands":["echo UTCP_ARG_text_UTCP_END"]}}]}''', 200)),
    );
    await source.discover();
    expect(source.cliPreview('echo', {'text': r"a'b $(rm x)"}), r"echo 'a''b $(rm x)'");
    await source.close();
  });
}

import 'package:ai_chatbot/data/models.dart';
import 'package:ai_chatbot/server/openai_bridge.dart';
import 'package:ai_chatbot/server/responses_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('assistant text and parallel calls form one replay turn, bounded by results', () {
    final parsed = parseResponsesRequest({
      'model': 'gemini/test',
      'input': [
        {'role': 'user', 'content': 'Fix'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'Checking'},
          ],
        },
        {
          'type': 'function_call',
          'name': 'read',
          'call_id': 'a',
          'arguments': '{"path":"a"}',
        },
        {
          'type': 'function_call',
          'name': 'read',
          'call_id': 'b',
          'arguments': '{"path":"b"}',
        },
        {'type': 'function_call_output', 'call_id': 'a', 'output': 'A'},
        {'type': 'function_call_output', 'call_id': 'b', 'output': 'B'},
        {'role': 'assistant', 'content': 'Finished'},
      ],
    });
    final turns = parsed.request.messages;
    expect(turns.length, 4);
    expect(turns[1].text, 'Checking');
    expect(turns[1].toolCalls.map((call) => call.id), ['a', 'b']);
    expect(turns[2].toolResults.length, 2);
    expect(turns[3].text, 'Finished');
  });
  test(
    'Codex custom patch calls round trip with tool output and done events',
    () {
      final parsed = parseResponsesRequest({
        'model': 'openai/test',
        'store': false,
        'stream': true,
        'tools': [
          {
            'type': 'custom',
            'name': 'apply_patch',
            'format': {
              'type': 'grammar',
              'syntax': 'lark',
              'definition': 'patch',
            },
          },
        ],
        'input': [
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'Fix'},
            ],
          },
          {
            'type': 'custom_tool_call',
            'name': 'apply_patch',
            'call_id': 'a',
            'input': '*** Begin Patch',
          },
          {
            'type': 'custom_tool_call_output',
            'call_id': 'a',
            'output': 'Applied',
          },
        ],
      });
      expect(
        parsed.request.messages[1].toolCalls.single.arguments['input'],
        '*** Begin Patch',
      );
      expect(
        parsed.request.messages.last.toolResults.single.name,
        'apply_patch',
      );
      final output = responsesOutput('Done', [
        ToolCall(
          id: 'a',
          name: 'apply_patch',
          arguments: {'input': 'raw patch'},
        ),
      ], parsed.customTools);
      expect(output.last['type'], 'custom_tool_call');
      expect(output.last['input'], 'raw patch');
      final result = responsesMessage(
        id: 'resp_a',
        model: 'openai/test',
        output: output,
        usage: UsageStats(inputTokens: 2, outputTokens: 3),
      );
      final events = responsesCompletedEvents(result).toList();
      expect(events[1].data['item'], output.last);
      expect(events.last.event, 'response.completed');
      expect((result['usage'] as Map)['total_tokens'], 5);
    },
  );
  test('unsupported stateful requests and server tools fail clearly', () {
    for (final extra in [
      {'previous_response_id': 'old'},
      {'store': true},
      {
        'tools': [
          {'type': 'web_search', 'name': 'search'},
        ],
      },
      {'tool_choice': 'required'},
    ]) {
      expect(
        () => parseResponsesRequest({
          'model': 'openai/test',
          'input': 'Hi',
          ...extra,
        }),
        throwsA(isA<BridgeException>()),
      );
    }
  });
}

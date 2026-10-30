import 'dart:async';

import '../models.dart';
import 'llm_provider.dart';

/// Offline provider that streams a canned reply. Used when the app is run
/// with `--dart-define=DEMO=true` (screenshots, UI work without a key).
class DemoProvider extends LlmProvider {
  DemoProvider(ProviderSettings settings) : super(settings: settings, apiKey: '');

  @override
  Stream<ChatDelta> streamChat(ChatRequest request) async* {
    final last = request.messages.lastWhere((m) => m.role == Role.user);
    final files = last.attachments.map((a) => '`${a.name}`').join(', ');
    final reply = '''
This is **demo mode**, so no API key is needed. Add a key in *Settings* to talk to a real model.

${files.isEmpty ? '' : 'You attached $files.\n\n'}Here is an example of formatted output:

| Provider | Vision | PDFs |
|---|---|---|
| Claude | ✓ | ✓ |
| ChatGPT | ✓ | ✓ |
| DeepSeek | – | text only |

```dart
void main() {
  print('Hello from your chatbot!');
}
```
''';
    yield const ChatDelta(reasoning: 'The user is trying the demo. ');
    for (final word in reply.split(RegExp(r'(?<= )'))) {
      await Future<void>.delayed(const Duration(milliseconds: 18));
      yield ChatDelta(text: word);
    }
  }

  @override
  Future<List<String>> listModels() async => settings.models;
}

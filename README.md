# Chatbot

A clean, Claude-style AI chat app for **Android** and **Windows**, built with Flutter.
Bring your own API key for **Claude, ChatGPT, DeepSeek, Gemini, OpenRouter, Groq**, or any
OpenAI-compatible server (Ollama, LM Studio, vLLM).

## Download

Get the latest build from the **[Releases page](https://github.com/Robokks/ai-chatbot/releases/tag/latest)**:

- **Android:** download `Chatbot-android.apk` on your phone and open it. Allow
  "Install unknown apps" for your browser when asked.
- **Windows:** download `Chatbot-windows-x64.zip`, unzip it, and run `ai_chatbot.exe`
  inside the folder. Keep the other files next to it. The exe is unsigned, so if
  SmartScreen warns, choose **More info → Run anyway**.

**No GitHub Actions? Build the APK in Google Colab:**
[![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Robokks/ai-chatbot/blob/ccr-85a70df3-vqfuzv/colab/build_apk.ipynb)
Choose *Runtime → Run all*. After about 15–20 minutes the APK downloads and is saved to your
Google Drive (`MyDrive/Chatbot`). If the repo is private, paste a read-only GitHub token when the
notebook asks.

These builds are made automatically by GitHub Actions on every push. They are signed with
Flutter's debug key, which is fine for personal use but not for the Play Store.

## Features

- **Multiple providers.** Switch models from the composer. Keys are stored encrypted on the
  device (Android Keystore / Windows Credential Manager) and sent only to the provider you
  chat with. There is no backend.
- **Streaming replies** with a stop button, regenerate, edit-and-resend, and copy.
- **File uploads:** photos, camera capture (Android), PDFs, and text/code files. Drag and drop
  works on Windows.
  - Images are downscaled to 1568px and sent to vision models.
  - PDFs go natively to Claude, ChatGPT and Gemini. For other providers the text is extracted
    and sent instead.
  - Text and code files are inlined with their filename.
- **Rich markdown:** syntax-highlighted code blocks with copy, tables, LaTeX, and links.
- **Thinking:** reasoning from Claude, DeepSeek-reasoner and Gemini appears in a collapsible
  "Thought process" section.
- **Chat history** grouped by date, with search, rename and delete. It is stored locally.
- **Claude-inspired design:** a warm palette, serif greeting, light/dark/system themes, a
  drawer on phones and a collapsible sidebar on desktop.
- **Keyboard shortcuts (Windows):** Enter sends, Shift+Enter adds a new line, Ctrl+N starts a
  new chat, Ctrl+, opens settings.

## Getting started

1. Install [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or later.
2. `flutter pub get`
3. Run it:
   - Android: `flutter run -d android` (device or emulator)
   - Windows: `flutter run -d windows`
   - Try the UI without a key: `flutter run --dart-define=DEMO=true`
4. Open **Settings → API keys**, paste a key, and tap **Test & load models**.

| Provider | Where to get a key |
|---|---|
| Claude | https://console.anthropic.com/settings/keys |
| ChatGPT | https://platform.openai.com/api-keys |
| DeepSeek | https://platform.deepseek.com/api_keys |
| Gemini | https://aistudio.google.com/apikey |
| OpenRouter | https://openrouter.ai/keys |
| Groq | https://console.groq.com/keys |

## Building releases

```bash
flutter build apk --release        # build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle --release  # Play Store
flutter build windows --release    # build/windows/x64/runner/Release/ (run on Windows)
```

The **Build** GitHub Actions workflow runs analyze and the tests, then uploads an Android APK
and a zipped Windows build as artifacts on every push.

Release APKs are signed with the debug key by default. Before publishing, configure your own
keystore (see [Flutter's Android release guide](https://docs.flutter.dev/deployment/android)).

## Project layout

```
lib/
  core/            theme, storage (Hive + secure key store), platform helpers
  data/models.dart conversations, messages, attachments, provider catalog
  data/llm/        provider adapters: Anthropic, OpenAI-compatible, Gemini, demo; SSE parser
  state/           AppState (ChangeNotifier) + AppScope
  features/
    chat/          chat screen, composer, message tiles, markdown, model picker
    sidebar/       history drawer / sidebar
    settings/      keys, models, theme, custom instructions
    attachments/   picking, image resizing, PDF text extraction
test/              SSE parser, provider request/stream tests, AppState tests
```

To add a provider that speaks the OpenAI Chat Completions API, add an entry to
`ProviderKind` in `lib/data/models.dart`. No other code is needed.

## Notes

- Claude requests use the Messages API (`anthropic-version: 2026-10-21`) with adaptive
  thinking (summarized). On Opus 5.5, Sonnet 5.5, Opus 5 and Fable 5.1 they also enable
  server-side refusal fallbacks (`fallbacks: "default"`).
- PDF text extraction uses `syncfusion_flutter_pdf`, which is free under the Syncfusion
  Community License for individuals and small companies. Check their terms for commercial use.
- Fonts (Inter, Source Serif 4, JetBrains Mono, SIL OFL) are bundled in `assets/google_fonts`.

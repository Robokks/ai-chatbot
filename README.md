# Chatbot

A clean, Claude-style AI chat app for **Android** and **Windows**, built with Flutter.
Bring your own API key for **Claude, ChatGPT, DeepSeek, Gemini, OpenRouter, Groq**, or any
OpenAI-compatible server (Ollama, LM Studio, vLLM).

## Download

Get the latest build from the **[Releases page](https://github.com/Robokks/ai-chatbot/releases/tag/latest)**:

- **Android:** download `Chatbot-android.apk` on your phone and open it. Allow
  "Install unknown apps" for your browser when asked. `Chatbot-android-x86_64.apk` is only
  for emulators and Intel Chromebooks.
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
- **On-device models (offline):** download a small GGUF model, such as Liquid AI's LFM2,
  Gemma 3 1B or Qwen 2.5 1.5B, or paste any Hugging Face `.gguf` link. It runs on the phone
  or PC through llama.cpp ([llamadart](https://pub.dev/packages/llamadart)), with no internet
  and no API key. See [Offline models](#offline-models).
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

## Offline models

Open **Settings → On-device models** (or the model picker → On-device → Download).

| Model | Download | RAM needed | Notes |
|---|---|---|---|
| LFM2 350M | 230 MB | ~1 GB | Tiny, very fast |
| LFM2 700M | 470 MB | ~1.5 GB | Fast on most phones |
| **LFM2 1.2B** | 730 MB | ~2 GB | Recommended |
| LFM2 2.6B | 1.6 GB | ~4 GB | Needs a recent phone or a PC |
| Gemma 3 1B | 810 MB | ~2 GB | |
| Qwen 2.5 1.5B | 1.1 GB | ~2.5 GB | Good at code |

- Use **+ → Add a GGUF model** to paste any Hugging Face link (`hf://owner/repo/file.gguf`)
  or pick a `.gguf` file already on the device. Q4_K_M files work best on phones.
- Expect roughly 5–20 words per second on a phone with a 1B model, and much faster on a PC.
  On-device models are simpler than the cloud models.
- Images aren't supported offline. Text files and PDF text are.
- Android needs a 64-bit phone with Android 10 or later. The model list lives in
  `lib/data/local/local_models.dart`.

## Home server (share models on your Wi-Fi)

Turn an old phone or a PC into a private AI server for your other devices.

**On the host** (e.g. the old phone): **Settings → Share this device**, then turn on
**Share AI on this Wi-Fi**. Choose what to share: on-device models, and optionally cloud
models that then use the host's API keys. On Android a notification shows while sharing; keep
the app open in the background.

**On your other devices:** **Settings → Connect to a home server**. The host appears
automatically; tap it and enter the 6-digit PIN shown on the host. You can also type the
address (e.g. `192.168.1.23:8484`). The shared models then appear in the model picker under
**Home server**.

**Other apps** (Open WebUI, Continue, the OpenAI SDKs, curl) can use the host's
OpenAI-compatible API. On the host, tap **Create access key**, then use:

```bash
curl http://192.168.1.23:8484/v1/chat/completions \
  -H "Authorization: Bearer cbh_..." -H "Content-Type: application/json" \
  -d '{"model": "local/LFM2-1.2B-Q4_K_M", "messages": [{"role": "user", "content": "Hi"}]}'
```

`GET /v1/models` lists what the host shares. Model ids look like `local/<model>` or
`anthropic/claude-sonnet-5-5`. Streaming (`"stream": true`) and
`stream_options.include_usage` work as with OpenAI.

The host also speaks the common tool and agent protocols, all with the same access key:

| Protocol | Address | Use it from |
|---|---|---|
| **MCP** (Streamable HTTP) | `http://<host>:8485/mcp` | Claude Desktop, Claude Code, Cursor, VS Code: tools `list_models` and `chat` |
| **UTCP** v1 manual | `http://<host>:8484/utcp` | UTCP clients: HTTP tools `list_models` and `chat` (`POST /tools/chat`); set the variable `CHATBOT_HOST_KEY` to your key |
| **A2A** 1.0 | Agent Card at `http://<host>:8484/.well-known/agent-card.json`, JSON-RPC at `/a2a` | Agent frameworks: `SendMessage` and `SendStreamingMessage`; pick a model with `metadata.model` |

For example, to add the host to Claude Code:

```bash
claude mcp add --transport http phone-ai http://192.168.1.23:8485/mcp \
  --header "Authorization: Bearer cbh_..."
```

Security: only paired devices and apps with an access key can use the server; remove a
device on the host to revoke it. Wrong PINs are rate-limited and the PIN rotates. Traffic on
the Wi-Fi isn't encrypted, so share only on networks you trust.

## Tools (MCP, UTCP, A2A, CLI)

The AI can use tools while it answers. Add them under **Settings → Tools**:

| Type | What you enter | Notes |
|---|---|---|
| **MCP server** | Streamable HTTP URL (+ optional bearer key) | Any MCP server; tools are listed automatically |
| **UTCP manual** | Manual URL (+ optional key, `NAME=value` variables) | HTTP tools are called directly; `cli` tools run on a PC if their programs are allowlisted |
| **A2A agent** | Agent URL or agent card URL (+ optional key) | Becomes an "ask" tool; A2A 1.0 and 0.3 |
| **CLI program** (Windows/PC) | Program name or path, e.g. `git` | Allowlist: the AI can only run programs you add, and **every run asks you first**, showing the exact command |

If you're paired with a home server, **Tools from <host>** adds its MCP tools in one tap.

Every tool call appears in the chat. Tap it to see the input and result. Tools from MCP, UTCP
and A2A run on their own unless you turn on **Ask before each run** for that source.
Tool use works with Claude, ChatGPT and other OpenAI-compatible APIs, Gemini,
on-device models (if the model supports tool calling) and models on your home server.

## Building releases

```bash
flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64
flutter build appbundle --release  # Play Store
flutter build windows --release    # build/windows/x64/runner/Release/ (run on Windows)
```

The **Build** GitHub Actions workflow runs analyze and the tests, then uploads an Android APK
and a zipped Windows build as artifacts on every push.

Release APKs are signed with the debug key by default. Before publishing, configure your own
keystore (see [Flutter's Android release guide](https://docs.flutter.dev/deployment/android)).

## Permanent signing key (one-time setup)

Android only installs an update over the old app when both are signed with the **same key**.
Without a key, each GitHub build uses a new temporary key, so you would have to uninstall the
app (and lose its chats) before every update. Set this up once:

1. Open https://colab.research.google.com, create a new notebook, paste this into a cell and run it:

   ```python
   import subprocess, base64, getpass
   pw = getpass.getpass("Choose a keystore password (min 6 chars): ")
   subprocess.run(["keytool", "-genkeypair", "-keystore", "upload-keystore.jks", "-alias", "upload",
                   "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
                   "-storepass", pw, "-keypass", pw, "-dname", "CN=Chatbot"], check=True)
   open("keystore-base64.txt", "w").write(base64.b64encode(open("upload-keystore.jks", "rb").read()).decode())
   from google.colab import files
   files.download("upload-keystore.jks"); files.download("keystore-base64.txt")
   ```

2. **Back up `upload-keystore.jks` and the password somewhere safe** (e.g. a password manager).
   If you lose them, existing installs can't be updated.
3. On GitHub: **Settings → Secrets and variables → Actions → New repository secret**. Add:
   - `ANDROID_KEYSTORE_BASE64`: the whole contents of `keystore-base64.txt`
   - `ANDROID_KEYSTORE_PASSWORD`: your password
   - `ANDROID_KEY_ALIAS`: `upload`
4. Re-run the latest build (Actions → Build → Re-run all jobs). From then on, every APK is signed
   with your key and installs as an update.

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

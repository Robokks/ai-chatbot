# Handover: Chatbot app (Flutter, Android + Windows)

Last updated: 2026-10-31 (third session). Repo `Robokks/ai-chatbot`. Work now continues on branch
**`ccr-9b78964b-7pqvaf`** (it contains everything from the older `ccr-85a70df3-vqfuzv`; there's no `main` yet;
the repo is public). §2A is finished and tested.

## Paste this into the new chat

> Continue the Flutter chatbot app in GitHub repo `Robokks/ai-chatbot`, branch
> `ccr-9b78964b-7pqvaf`. Read `docs/HANDOVER.md` first. It describes the project, the
> decisions made, and the unfinished work (section 2). Ask me which item in §2B/§2C to do next.
> Work on the same branch and push there. Keep `flutter analyze` clean and all tests passing.

---

## 1. What the app is

A Claude-style AI chat app (warm cream/terracotta design) for **Android first, Windows second**,
built in Flutter. The user owns the repo (email karthi96pmk@gmail.com) and is not a
developer. Explain things simply, give download links, and avoid jargon.

Features done:
- **Cloud models with the user's own API keys**: Claude, ChatGPT, DeepSeek, Gemini, OpenRouter,
  Groq, and custom OpenAI-compatible servers. Streaming, thinking display, markdown/code/tables/LaTeX.
- **Attachments**: camera, photos, PDFs, text/code files; drag-and-drop on Windows.
- **On-device (offline) models** via `llamadart` (llama.cpp GGUF):
  - Liquid AI LFM2 350M/700M/1.2B/2.6B, Gemma 3 1B and Qwen 2.5 1.5B, all with SHA-256 pinned.
  - Custom GGUF links or files.
  - Background downloads with resume (`background_downloader`).
- **Usage details**:
  - per-reply tokens, speed and cost (Claude list prices only);
  - device RAM/storage meters and app storage;
  - API usage totals;
  - "Fits this device" labels on models.
- **Home server ("Share this device")**:
  - the phone or PC serves its models on the LAN through an OpenAI-compatible API;
  - mDNS discovery (`bonsoir`) and 6-digit PIN pairing that rotates and is rate-limited;
  - per-device access keys;
  - an Android foreground service keeps it running.
- **The host also speaks**:
  - **MCP** (Streamable HTTP, `mcp_dart`) on port **8485** `/mcp`;
  - a **UTCP** v1 manual at `/utcp`;
  - **A2A 1.0**: Agent Card at `/.well-known/agent-card.json`, JSON-RPC at `/a2a`.
  - ACP was merged into A2A; the user chose A2A.
- **Tool use in chat**:
  - MCP servers, UTCP manuals (http and cli templates), A2A agents, CLI programs.
  - Agent loop of up to 10 rounds, with approval cards. CLI always asks first.
  - Works with Claude (signed thinking blocks replayed), OpenAI-compatible APIs, Gemini
    (thought signatures), and local models.
  - The home server forwards tools both ways.
- **Built-in phone tools** (no setup):
  - web search (DuckDuckGo HTML) and reading web pages, with private/LAN IPs and redirects to
    them blocked;
  - calculator, date/time, device info (battery via a native channel);
  - notes (delete asks first).
- **Security work done**:
  - no auto-loaded images in replies (exfiltration);
  - only http/https/mailto links, with a confirm step;
  - model-id path-traversal fix;
  - Android backup disabled;
  - CI actions pinned to SHAs with read-only permissions;
  - release signing with the user's **permanent key** (done; see §2D);
  - model checksums.

## 2. In progress / next steps

### 2A. Claude Code / Codex from the offline PC: DONE

All 10 tests in `test/coding_agents_test.dart` passed on the first run (99 tests in total). One fix was
needed: the app checked `claude --version` / `codex --version` at every launch, which left a 20 s
timer that broke `attach_sheet_test`. Now `AgentHub.ensureDetected()` runs only when sharing starts
or the Coding agents card opens. README section "Use Claude Code / Codex from another PC" added.
The notes below describe the design.

**Need:** the user has 2 Windows PCs on one LAN. Only one has internet, and Claude Code and Codex are installed there only. From the offline PC they want to use Claude Code and Codex through this app. The plan was approved; it's in the old plan file and summarized here.

**Design:** the internet PC runs the home server. It offers MCP tools `claude_code` and `codex`. The offline PC adds them with Tools → "Tools from <host>" (that already exists). Each run asks on the offline PC first (destructive tool), then shows **Allow / Allow for 30 min / Deny** on the internet PC. No answer in 2 minutes means deny.

New files:
- `lib/server/coding_agents.dart`:
  - `CodingAgent` enum: program `claude` or `codex`, MCP tool names, install hints.
  - `AgentFolder` and `AgentSettings`, saved in setting `host.agents`.
  - `agentArgs()`: **fixed words only. The task goes in through stdin and the folder is the working directory**, so prompt text can't become shell code. This matters because Windows runs the npm `.cmd` shims through cmd.exe with `runInShell`.
    - Claude Code: `claude -p --output-format text --permission-mode plan|acceptEdits [--continue]`.
    - Codex: `codex exec --skip-git-repo-check --sandbox read-only|workspace-write`, with the prompt from stdin. Codex has no continue, because the `exec resume` syntax wasn't verified.
  - `detectAgent()` runs `--version`.
  - `runAgent()`: `Process.start`, progress ticks, 20-minute kill, `clip()`.
  - `HostApproval`.
- `lib/server/agent_hub.dart`: `AgentHub` (ChangeNotifier, implements `AgentHost`). It holds settings, detection (`versions`), the `pending` approvals queue, `answer()`, `allowAllUntil` ("Allow for 30 min" trusts **all** runs, not just one device), `denyAll()`, and `runAgentTask()`, which logs to the host log through `server.logEvent`.
- `lib/features/host/agents_card.dart`:
  - `AgentsCard`, on the host screen in section "Coding agents", PC only: agent switches with version or install hint; a folder list with Add (`FilePicker.getDirectoryPath`) and Read only / Can edit.
  - `AgentApprovalOverlay`: in `MaterialApp.builder` in `lib/app.dart`, so the box shows over every screen.
- `test/coding_agents_test.dart`: **written, never run.** It uses `sh` fake agents and a real host plus `ToolRegistry`, like `test/tools_test.dart`, and imports `HostBackendFake` from it.

Changed files:
- `host_mcp.dart`: the `AgentHost` interface; `_registerAgents` registers tools only when an agent is enabled, detected, and at least one folder exists. Input is `{task, folder (enum of labels), continue_last}`, with `ToolAnnotations(destructiveHint: true)`. It sends `extra.sendProgress` every 15 seconds.
- `host_server.dart`: optional `agents`; the MCP authorizer records the last device name (`_lastMcpDevice`) because mcp_dart gives tool callbacks no request or auth info, so device names are best effort; `logEvent()`.
- `host_controller.dart`: creates `agents` (AgentHub). `agentsSupported = desktopCli`. `stop()` denies anything pending.
- Client side:
  - `mcp_source.dart`: tools with annotations that are destructive and not read-only become `alwaysAsk`. `callTool` uses `RequestOptions(timeout: 2m, resetTimeoutOnProgress: true, maxTotalTimeout: 25m, onprogress → onProgress)`. `callTimeout` is 26 minutes.
  - `tool_source.dart`: added `onProgress` and `callTimeout`.
  - `tool_registry.dart`: `execute(call, {onProgress})`, with a per-source timeout.
  - `app_state.dart`: progress text goes to `streamingStatus`.

Original TODO (all done):
1. `export PATH=/opt/flutter/bin:$PATH` (in the cloud container), then `flutter test test/coding_agents_test.dart` and fix any failures. Possible weak spots:
   - the stateless MCP 2026-07-28 protocol and progress notifications (if `sendProgress` gets no progressToken, progress silently does nothing; then check that the client sends one);
   - `JsonSchema.boolean`/`enumValues` serialisation;
   - the `alwaysAsk` mapping.
2. Run all tests (89 before, plus about 9 new), push **without** `[skip ci]`, and check the Windows job builds.
3. README: a "Use Claude Code / Codex from another PC" section with simple steps:
   1. Internet PC: Share this device → Coding agents → switch on, add folder.
   2. Offline PC: pair → Tools → "Tools from <PC>".
   3. Chat: "ask Claude Code to …" → approve on both PCs.
4. Tell the user the steps above in simple words.

### 2B. NEW REQUEST (not planned yet): image generator, OCR for PDFs, voice cloner, on device

The user wrote: "Integrate Image generator & ocr pdf voice cloner. All open source model, less space consumption model." They want plan mode first. Research so far: the `llamadart` 0.17 package the app already uses (see its README in the pub cache) supports all three.
- **Image generation**: `ImageGenerationEngine` (stable-diffusion.cpp). Preview; Android arm64 CPU and Windows x64 are supported. It needs the runtime enabled: in `pubspec.yaml` `hooks: user_defines: llamadart: llamadart_native_runtimes: [llama_cpp, stable_diffusion]` (today it's limited to llama_cpp CPU; check the existing user_defines). That adds about 40–70 MB per target to the APK. It was validated with **SDXS** (very small, 512px, fast) and **SD-Turbo**, so SDXS is the small model to offer. Check licenses.
- **OCR**: a small vision GGUF plus its mmproj projector through llamadart multimodal, e.g. Liquid AI **LFM2-VL-450M** (the user likes LFM) or SmolVLM-256M. Scanned PDFs need pages turned into images first; `pdfrx` is one option, but check its size. The app already pulls text from PDFs that have a text layer.
- **Voice cloning**: llamadart has experimental `TextToSpeechEngine` with `Qwen3TtsAdapter`. Native code shows a `SPEAKER_REFERENCE` capability, so cloning from a short reference clip may work with Qwen3-TTS 0.6B Base; **check this in `lib/src/core/speech/text_to_speech.dart`**. Also add audio recording and playback packages. Safety: add a consent note, e.g. "Only clone your own voice or a voice you have permission to use", and label output as AI-generated.
- Other ideas: run the heavy ones on the PC host and share them over the home server (the user likes that pattern), and show "Fits this device" checks (`modelFit`).
- Next step: enter plan mode, ask the user which to do first and whether they're phone-only or the PC host too, then write the plan.

### 2C. Older open items
- **Termux setup guide UI and tests**: not done. The Kotlin bridge, manifest, `lib/tools/termux.dart` and the CLI wiring are done, and they compiled in CI.
  - In `tools_screen.dart` `SourceScreen` (type cli, Android), show 4 steps, each with a ✓ from `TermuxRunner.instance.isInstalled()` / `hasPermission()`:
    1. Install Termux from F-Droid.
    2. `echo "allow-external-apps=true" >> ~/.termux/termux.properties && termux-reload-settings`.
    3. **Grant permission** button.
    4. `pkg install git python`.
  - Show "Add CLI program" on Android before Termux is ready.
  - `test/termux_test.dart` with a fake runner.
- **Sharing any PC CLI program to the phone, approved on both devices**: not started. Reuse the 2A approval system: `AgentHub`'s pending queue and the overlay.
- **Bigger offline models (paused by the user)**: in `git stash` `"bigger models (paused by user)"`. That stash is in the old container only and is **lost** in a new one, so redo it from this note: add Gemma 3 4B (`unsloth/gemma-3-4b-it-GGUF`, `gemma-3-4b-it-Q4_K_M.gguf`, about 2400 MB, needs 5 GB RAM) and Qwen 2.5 3B (`Qwen/Qwen2.5-3B-Instruct-GGUF`, `qwen2.5-3b-instruct-q4_k_m.gguf`, about 2000 MB, needs 4 GB RAM) to `builtInLocalModels`. Let `model-check.yml` print the SHA-256 values, then pin them. Only do this when the user says so.
- **Play Store publishing**: a plan exists, on hold. App id `com.robokks.chatbot`. It needs a privacy policy page, a store kit, an in-app "Report" button for AI replies, and a closed test (12 testers, 14 days).

### 2D. Done since the last handover
- **Permanent signing key** is set up. The user made it with `colab/make_signing_key.ipynb` (a Drive copy exists; the backup is in `MyDrive/Chatbot/signing-key/`) and added the secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS`. CI run 41220707817 signed with it, and that run's APK is in the `latest` release. Told the user to uninstall the old app **one last time**; from now on updates install over it and keep their data. **Never change the key**, or the user loses data again.
- Download progress fix (`3530e64`).
- Answered: an offline PC can use AI through the internet PC by running the home server on the internet PC and pairing the offline PC (already works).

## 3. Build, run, test

- **Flutter 3.47.9** (Dart 3.13). Material is the separate package `material_ui`: **import `package:material_ui/material_ui.dart`, not `package:flutter/material.dart`**, because newer packages use material_ui types.
- `flutter pub get`, `flutter analyze` (must say "No issues"), and `flutter test` (89 tests passing at `399e547`; plus `test/coding_agents_test.dart`, not run yet).
- UI preview without a phone: `flutter build web --dart-define=DEMO=true --no-web-resources-cdn`, then serve `build/web` and take Playwright screenshots. Widget screenshots are also done in throwaway tests that load the fonts from `assets/google_fonts` (see past commits).
- **CI**: `.github/workflows/build.yml` runs analyze, test, `flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64`, `flutter build windows`, then publishes the **`latest`** pre-release with `Chatbot-android.apk` (arm64), `Chatbot-android-x86_64.apk` and `Chatbot-windows-x64.zip`. Download page: https://github.com/Robokks/ai-chatbot/releases/tag/latest
- `.github/workflows/model-check.yml` checks the built-in model links and prints their SHA-256 values.
- `colab/build_apk.ipynb` is an alternative APK build. A Drive copy exists; it's not needed now that CI works.

## 4. Architecture map (lib/)

- `data/models.dart`:
  - `ProviderKind` (anthropic, openai, deepseek, gemini, openrouter, groq, **local**, **network** = home server, custom);
  - `Message` (with `toolCalls`, `toolResults`, `providerBlocks`, `usage`);
  - `ToolSpec`, `ToolCall`, `ToolResult`, `UsageStats`, `Conversation`.
- `data/llm/`: one `LlmProvider` per API.
  - `streamChat(ChatRequest)` yields `ChatDelta`s: text, reasoning, usage, toolCalls, providerBlocks, notice, status.
  - Files: `anthropic_provider.dart` (Messages API `2026-10-21`, adaptive thinking, `fallbacks: "default"` beta), `openai_provider.dart` (also DeepSeek, OpenRouter, Groq, network, custom), `gemini_provider.dart`, `local_provider.dart` (llamadart, one engine with a queue), `demo_provider.dart`.
- `data/local/`: `local_models.dart` (catalog plus `LocalModelStore`) and `model_downloader.dart` (background or HTTP downloads with resume).
- `state/app_state.dart`: `AppState` (ChangeNotifier exposed through `AppScope`) holds the agent loop `_reply`, approvals (`ToolApprovalRequest`), host connect/disconnect, and `tools` (`ToolRegistry`).
- `server/`:
  - `host_server.dart`: dart:io HttpServer with routes `/health`, `/pair`, `/v1/models`, `/v1/chat/completions`, `/utcp`, `/tools/chat`, `/a2a` and the agent card.
  - `openai_bridge.dart` (OpenAI ⇄ internal, including tools and `x_provider_blocks`), `host_mcp.dart`, `host_protocols.dart`, `host_controller.dart`, `discovery.dart`, `foreground.dart`.
- `tools/`: `tool_registry.dart` plus sources `mcp_source`, `utcp_source`, `a2a_source`, `cli_source`, `builtin_source`, with `cli_runner` and `termux`.
- `features/`: chat, sidebar, settings (local models, usage), host (connect, host), tools.
- Storage:
  - Hive boxes `conversations`, `blobs` and `settings`;
  - secrets (API keys, host device keys, tool keys) in `flutter_secure_storage` through `Storage.readSecret`/`writeSecret` and `readKey`/`writeKey`.

## 5. Decisions and user preferences

- Answers to the user should be short, simple and practical. The user often asks "what happened", so report status plainly. The user's English is basic.
- The user wanted plan mode for big features, with approval before starting.
- Prices: show costs only for Claude (verified list prices); token counts for others.
- Tools: CLI always needs approval. MCP/UTCP/A2A auto-run unless "Ask before each run" is on.
- Web search: DuckDuckGo with no key (the user's choice).
- PC CLI from the phone: approve on **both** devices (the user's choice).

## 6. Gotchas

- Model downloads (`background_downloader`) must set `updates: Updates.statusAndProgress`. The
  default sends no progress, which left the bar stuck at 0% (fixed in `3530e64`; downloads started
  before that fix finish fine but show no percentage). The screen also shows speed and time left
  (`speedText` in `model_downloader.dart`).

- `battery_plus` conflicts with `bonsoir` (dbus versions), so battery is read through the native `chatbot/device` channel instead.
- `desktop_drop` must stay at ^0.7 (cross_file conflict with file_picker 13).
- `llamadart` user_defines in `pubspec.yaml` limit Android to the CPU llama.cpp runtime (smaller APK). Android needs `minSdk 29`, 64-bit only.
- Android `network_security_config.xml` allows cleartext, for LAN home servers.
- The MCP server runs on its own port (`StreamableMcpServer`), main port + 1. Tool callbacks get no HTTP request or auth info (`RequestHandlerExtra.requestInfo`/`authInfo` are never filled), so the device name comes from the last authorized request.
- In the cloud container Flutter is at `/opt/flutter/bin` (it's not on PATH). A fresh container may not have it: `git clone --depth 1 -b 3.47.9 https://github.com/flutter/flutter.git /opt/flutter`.
- Claude tool loops need the signed thinking blocks replayed unchanged (`Message.providerBlocks`). Through the home server they travel as `x_provider_blocks`.
- The web build has no llama.cpp, no server and no CLI. It's for demos and screenshots only.

## 7. Git conventions

Commit messages end with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GbaKe1ExEvqeDzkzNJrYLS
```

(A new session should use its own session link if its system prompt gives one.) Push with
`git push origin ccr-9b78964b-7pqvaf`. No PRs unless the user asks. Don't put model IDs in commits.

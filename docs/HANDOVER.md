# Handover: Chatbot app (Flutter, Android + Windows)

Last updated: 2026-10-31. Repo `Robokks/ai-chatbot`, branch **`ccr-85a70df3-vqfuzv`** (no `main`
yet; the repo is public). Latest commit at handover: `fd17bb2`.

## Paste this into the new chat

> Continue the Flutter chatbot app in GitHub repo `Robokks/ai-chatbot`, branch
> `ccr-85a70df3-vqfuzv`. Read `docs/HANDOVER.md` first. It describes the project, the
> decisions made, and the unfinished work (section "In progress / next steps"). Work on the same
> branch and push there. Keep `flutter analyze` clean and all tests passing. The GitHub Actions
> "Build" workflow publishes the APK and Windows zip to the `latest` release.

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
  - optional release signing from secrets;
  - model checksums.

## 2. In progress / next steps (approved plan, "Tools that work on the phone")

The user approved three parts:

1. **Built-in phone tools**: DONE (`lib/tools/builtin_source.dart`, wired into `tool_registry.dart` and `tools_screen.dart`).
2. **CLI on Android via Termux**: mostly done.
   - Done:
     - Kotlin: `MainActivity.kt` has channels `chatbot/termux` (`isInstalled`, `hasPermission`, `requestPermission`, `run`) and `chatbot/device` (`battery`). `TermuxResultReceiver.kt` receives results from Termux `RunCommandService` through a mutable PendingIntent.
     - Manifest: `com.termux.permission.RUN_COMMAND`, `<queries><package com.termux>`, the receiver.
     - Dart: `lib/tools/termux.dart` (`TermuxRunner`, `ChannelTermuxRunner`, `termuxOutput`).
     - `cli_runner.dart`: `cliSupported` = desktop, or Android with `TermuxRunner.ready`.
     - `cli_source.dart` and the UTCP `_callCli` use Termux on Android.
     - `ToolRegistry.load()` calls `TermuxRunner.refresh()`.
   - TODO:
     - **Setup guide UI.** In `lib/features/tools/tools_screen.dart`, `SourceScreen`, when `type == cli` on Android, show 4 steps, each with a ✓ from `TermuxRunner.instance.isInstalled()` / `hasPermission()`:
       1. Install Termux from F-Droid (open `https://f-droid.org/packages/com.termux/`).
       2. Copy the command `echo "allow-external-apps=true" >> ~/.termux/termux.properties && termux-reload-settings`.
       3. A **Grant permission** button (`requestPermission()`, then `TermuxRunner.refresh()`).
       4. Install programs with `pkg install git python`.
     - In `ToolsScreen`, show "Add CLI program" on Android even before Termux is ready (`TermuxRunner.isAndroid`). Fix the note text: CLI is available on Windows, and on Android via Termux.
     - **Tests** (`test/termux_test.dart`) with a fake `TermuxRunner`: success; non-zero exit; `err` != 0 with an `allow-external-apps` hint; not installed; no permission. Also `termuxOutput` formatting.
     - The Kotlin code has **not compiled yet**. CI is the first compile, so check the Android job log after pushing.
3. **The PC's CLI programs shared to the phone, approved on BOTH devices**: NOT STARTED.
   - Host setting **"Share CLI programs with paired devices"**: off by default, stored in `host.settings` (`host_controller.dart`), shown in `host_screen.dart` only when `desktopCli`.
   - `host_mcp.dart`: when enabled, register `run_<slug>` for each enabled CLI config in `app.tools.configs`, with input `{args: string[], cwd?: string}` and `annotations: ToolAnnotations(destructiveHint: true)`.
     - The callback first awaits a **host approval**: add `Future<bool> Function(String device, String command)? approveRun` to `HostServer`/`HostMcpServer`. `HostController` exposes `pendingRemoteRun` (device, command, a Completer) and auto-denies after 2 minutes.
     - Then it runs `runProcess` and logs to `server.log`.
     - The MCP callback has no device identity; use the bearer key → `server.authenticate` on the request if mcp_dart exposes it, otherwise label it "Paired device".
   - Host UI: an approval banner in `features/home/home_shell.dart` (visible anywhere in the app) and on `host_screen.dart`, with Allow/Deny and the command in monospace.
   - Phone side: in `lib/tools/mcp_source.dart` `discover()`, set `alwaysAsk: t.annotations?.destructiveHint == true`. This applies to all MCP servers. The phone already has one-tap "Tools from <host>" (`tools_screen.dart` `_addHostTools`).
   - Tests: shared only when the setting is on; host approve/deny/timeout; phone marks destructive tools as always-ask. Model them on the real-host tests in `test/tools_test.dart`.
4. After each part: run `flutter analyze` and `flutter test`, commit with the attribution trailer (see §7), push, watch the CI "Build" run, and update the README "Tools" section.

Other open items the user mentioned earlier (not started):
- **Play Store publishing.** A plan exists, waiting for the user's go-ahead.
  - App id already `com.robokks.chatbot`.
  - Needs a privacy policy on GitHub Pages and a store kit (icon, feature graphic, screenshots, listing text, data-safety answers).
  - Generative-AI policy needs an in-app "Report" action on AI replies.
  - Contact email for the policy not confirmed (asked whether to show karthi96pmk@gmail.com).
  - New personal Play accounts need a closed test with 12 testers for 14 days.
- **Permanent signing key.** The workflow supports it; the user must add secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` (steps in the README). Until then every CI build has a new debug key, so the user must uninstall before updating.

## 3. Build, run, test

- **Flutter 3.47.9** (Dart 3.13). Material is the separate package `material_ui`: **import `package:material_ui/material_ui.dart`, not `package:flutter/material.dart`**, because newer packages use material_ui types.
- `flutter pub get`, `flutter analyze` (must say "No issues"), and `flutter test` (88 tests at handover, all passing).
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

- `battery_plus` conflicts with `bonsoir` (dbus versions), so battery is read through the native `chatbot/device` channel instead.
- `desktop_drop` must stay at ^0.7 (cross_file conflict with file_picker 13).
- `llamadart` user_defines in `pubspec.yaml` limit Android to the CPU llama.cpp runtime (smaller APK). Android needs `minSdk 29`, 64-bit only.
- Android `network_security_config.xml` allows cleartext, for LAN home servers.
- The MCP server runs on its own port (`StreamableMcpServer`), main port + 1.
- Claude tool loops need the signed thinking blocks replayed unchanged (`Message.providerBlocks`). Through the home server they travel as `x_provider_blocks`.
- The web build has no llama.cpp, no server and no CLI. It's for demos and screenshots only.

## 7. Git conventions

Commit messages end with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GbaKdxwm5ViashJ3vqDUQD
```

(A new session should use its own session link if its system prompt gives one.) Push with
`git push origin ccr-85a70df3-vqfuzv`. No PRs unless the user asks. Don't put model IDs in commits.

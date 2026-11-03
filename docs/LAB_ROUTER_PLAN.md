# Lab AI Router plan (Windows): approved 2026-11-03

## Context
The user runs a **small lab on its own network**: no company domain, no IT involved. One **Main PC** has internet over Wi-Fi and is also on the lab Ethernet. The other PCs can't have internet, for different reasons, and are on Ethernet only. Some PCs have a second Ethernet port, with more PCs behind them.

They want one Windows app that works like **FreeLLMAPI**, which they installed and showed in screenshots: Models, routing and fallback chains, Keys, Analytics, Playground, Agents. On top of that:
- every lab PC gets AI through Main;
- each offline PC runs its own tools;
- PCs can pass the service on (mesh/relay);
- Main monitors everything and can deny any PC.

**User decisions:**
- Tools run on the PC that asks.
- Main picks which models each client gets.
- Main is on the lab Ethernet.
- Approvals need an **expiry and limits**.
- Use the **clean white/black look like FreeLLMAPI**.
- **Step 1 uses FreeLLMAPI as a source; step 2 builds our own routing.**
- **Add LabVIEW support.** The user's own app `Robokks/labview-ai-assist` ("DynasBrain") already serves MCP at `/mcp` (`dynasbrain serve`) and uses Claude and Codex.

Same Flutter codebase (`Robokks/ai-chatbot`, branch `ccr-85a70df3-vqfuzv`). Android keeps working, but this plan is Windows first.

## Roles (one app, chosen at first start, changeable in Settings)
| Role | Has internet | Does |
|---|---|---|
| **Main** | yes | Holds all AI sources. Approves, limits and blocks clients. Dashboard. Shared services (web search, git/package proxy). |
| **Client** | no | Chats with the models Main allows. Runs its own tools: PowerShell, cmd, code, git, MCP, LabVIEW. |
| **Relay** | no | A client that also serves PCs behind it (second Ethernet port). It forwards their requests upstream, tagged with who sent them. Main sees and approves those PCs too. |

## Screens (left menu, clean white/black, like FreeLLMAPI)
**Main:**
1. **Chat** (FreeLLMAPI's Playground): model "Auto", system prompt, web search switch, attachments. It shows "Answered by X · 2 fallbacks".
2. **Models:** every model from every source, with on/off, filters (Vision, Tools, context size), token budget bar, routing strategy (Fastest, Most reliable, Smartest, Manual) and fallback chains.
3. **Keys / Sources:** Claude, ChatGPT, DeepSeek, Gemini, OpenRouter and Groq keys; **FreeLLMAPI as one source** (URL plus unified key); offline GGUF models; Claude Code and Codex (detected). Each has a health check.
4. **Clients** (new, the core screen):
   - all PCs, online or offline, and their path (direct, or through which relay);
   - pending requests with **Approve for 1 h / 1 day / 7 days / always** or **Deny**;
   - for each PC:
     - allowed models;
     - allowed tools and services (Claude Code, Codex, web search, git proxy);
     - limits (requests/day, tokens/day);
     - expiry;
     - **Block**.
   - A **Stop all** switch at the top.
5. **Analytics:** requests, success rate, tokens, speed and failures, **split by PC and by model**, over 24 h / 7 d / 30 d.
6. **Logs:** every request: time, PC, model, tool, status.
7. **Agents:** Claude Code and Codex sharing (the 2A work), plus one-click setup of *local* Claude Code on clients (see Phase 2).
8. **Settings:** role, network port, theme.

**Client:** Chat, Tools, Settings. A status bar shows, for example, "Connected to Main · Claude Code allowed until 6 PM · 120/500 requests left". When access is missing, there's a **"Request access"** button.

## Build order

### Phase 0: foundation
- Finish and test the uncommitted 2A work: Claude Code and Codex shared from the host, with approval (see `docs/HANDOVER.md` §2A). Its approval queue becomes the general approval system.
- New **clean white/black theme** and **left-menu desktop layout** for Windows (`lib/core/theme.dart`, `features/home/home_shell.dart`). Keep the current look as an option, and on Android.
- A first-start **role picker**: Main, Client or Relay.

### Phase 1: working lab, the MVP
- **Main sources:** FreeLLMAPI through the existing Custom OpenAI-compatible provider, made shareable. Today `HostController.shareableCloud` leaves Custom out, so add it there. Also allow several named custom sources.
- **Clients and access rules** (extends `HostServer`'s `PairedDevice`): an access policy per device holding the model allowlist, tool and service allowlist, limits, expiry and blocked flag. The checks happen in `HostServer` for `/v1/chat/completions`, MCP and A2A. Requests over a limit or past expiry get a clear error ("ask Main for more access"). Clients send an **access request** that shows on Main for approval.
- **Clients screen** and **Stop all**.
- **Client mode:** connects to Main (the existing pairing with PIN and discovery), uses only the allowed models, and shows remaining access.
- **Client tools run locally:** PowerShell and cmd (built-in, an allowlist plus "ask before run"), code running (Python or Node if installed), git (local commands), MCP servers. These reuse `ToolRegistry`, `CliToolSource` and `cli_runner.dart`, with PowerShell made a first-class built-in tool.
- **Web search through Main:** Main offers `web_search` and `read_web_page` (from `builtin_source.dart`) as host MCP tools. Clients use them like built-in tools.
- Basic **Logs**, with the device name on every entry.

### Phase 2: lab power features
- **Relay mode:** a relay runs a host server and forwards to its upstream (Main or another relay). It adds a signed hop chain (`via` headers with the relay's own key), so Main sees the real PC. New PCs behind a relay pair through it, and Main approves them.
- **Main proxy for git, pip and npm:** a restricted HTTP(S) forward proxy on Main.
  - Allowlist only: github.com, pypi.org, npmjs.org and the like.
  - Approved per PC, and logged.
  - Clients set `git config http.proxy` / `pip --proxy` / `npm config set proxy`, which the app does with one click. This makes git push/pull and package installs work on offline PCs.
- **Anthropic-compatible endpoint on Main** (`/v1/messages`, passed through to FreeLLMAPI's or translated). Offline PCs can then run **their own Claude Code** with `ANTHROPIC_BASE_URL=http://<Main>:8484` and their per-PC key; the app writes that config for them. Codex works the same way through `/v1`.
- **Analytics** charts, split by PC and model.
- **Faster fallback:** short timeouts, then the next model. Model health scores come from our own traffic.

### Phase 3: own engine and extras
- **Built-in routing engine** to replace FreeLLMAPI: provider adapters for the free tiers (Google AI Studio, Groq, NVIDIA NIM, OpenRouter, Cloudflare Workers AI), key rotation, quota tracking, strategies and fallback chains. The same screens, so nothing changes for the user.
- **Main sends app updates** to clients over the LAN.
- **LabVIEW** (details to agree when we get there):
  - add **DynasBrain's MCP** (`dynasbrain serve` → `/mcp` on a LabVIEW PC) as a tool source with one click, and share it through Main;
  - point DynasBrain's Claude and Codex at Main's endpoints, so it works on offline LabVIEW PCs;
  - a "LabVIEW expert" chat preset.

## Safety (from the start)
- Every request needs a per-PC key. Lab network only; nothing is exposed to the internet.
- Main's rules apply to everything: models, tools, proxy and relay hops. There are logs and Stop all.
- Commands on a client always run on that client and ask its user first, unless the client's user marks the tool "trusted".
- Claude Code / Codex edits: approval on Main with expiry (from 2A).

## Verification (per phase)
- Unit and integration tests, as in `test/host_server_test.dart` and `test/coding_agents_test.dart`:
  - policy checks: model allowlist, limits, expiry, block, Stop all;
  - the relay hop chain;
  - the proxy allowlist;
  - the `/v1/messages` translation.
- CI Windows build; `flutter analyze` clean.
- **Manual lab test by the user:**
  1. Main plus 1 client: the client sees only the allowed models; approval expires; Block works.
  2. Main plus relay plus a PC behind it: Main sees the far PC.
  3. The client runs PowerShell, git push through the proxy, and web search.
  4. Claude Code on the client through Main.


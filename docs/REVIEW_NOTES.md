# Review notes: fixes to do (for DeepSeek or the next chat)

The review was done by DeepSeek and confirmed by Claude on 2026-11-03. The baseline is `flutter analyze` clean and
**99 tests passing** (89 old + 10 in `test/coding_agents_test.dart`), checked on Linux.
Work on branch `ccr-85a70df3-vqfuzv`. Do **one fix per commit**, each with a test. GitHub CI is the test
runner if your PC has no Flutter.

Already fixed: the coding-agent check (`claude --version` / `codex --version`) no longer runs at app
start. It runs when the host screen opens or the server starts (`AgentHub.ensureDetected`).

## Fix in this order

### 1. A late "Allow" loses the answer
- **Where:** `lib/server/agent_hub.dart`, `runAgentTask` → `await _approve(approval)` (about line 146).
- **Problem:** while the host waits for the user to approve (up to 2 minutes), no progress is sent.
  The client (`lib/tools/mcp_source.dart`, `RequestOptions(timeout: 2 min, resetTimeoutOnProgress: true)`)
  can give up just before the user clicks Allow.
- **Fix:** before `_approve`, start `Timer.periodic(progressEvery, ...)` that calls
  `onProgress?.call(elapsed, 'Waiting for approval on the host…')`. Cancel it in a `finally` after `_approve`.
- **Test:** in `test/coding_agents_test.dart`, wait more than 2 progress intervals before `hub.answer`,
  then check that the `progress` list has an entry containing "Waiting for approval".

### 2. No cancel: the agent keeps running if the client stops or disconnects
- **Where:** `lib/server/host_mcp.dart`, the agent tool callback (about line 143), which receives `extra`.
  `extra.signal` is an mcp_dart `AbortSignal`: `aborted` (bool) and `onAbort` (`Stream<void>`).
  `lib/server/coding_agents.dart`: `runAgent`, where the process waits at `process.exitCode.timeout(...)`
  (about line 184).
- **Fix:**
  - Add an optional `Future<void>? cancel` parameter to `runAgent` and to `AgentHost.runAgentTask` /
    `AgentHub.runAgentTask`.
  - In host_mcp, pass `extra.signal.onAbort.first`.
  - In `runAgent`, when `cancel` completes: `process.kill()` and return
    `ToolOutput('Cancelled by the client.', isError: true)`.
  - If it's cancelled while still waiting for approval, remove the approval from `pending` (call
    `approval.decide(false)`).
- **Test:** run `runAgent` directly with a launcher that runs `sh -c 'sleep 30'` and a `Completer` as
  `cancel`. Complete it after 200 ms, and expect the result within about 2 seconds with "Cancelled".

### 3. Security: PowerShell quoting in UTCP CLI tools (Windows)
- **Where:** `lib/tools/utcp_source.dart` `_callCli` (about line 192) and `cliPreview` (about line 234) use
  `shellQuote` from `lib/tools/cli_runner.dart` (line 32). On Windows the script runs in
  **PowerShell** (`powershell -NoProfile -Command`), but `shellQuote` makes cmd-style `"..."`.
  Inside double quotes PowerShell runs `$(...)`, so a value can run commands.
- **Fix:**
  - Add `String powershellQuote(String v) => "'${v.replaceAll("'", "''")}'";` in `cli_runner.dart`.
  - Use it in both places when on Windows.
  - To make it testable, choose the quote function through a parameter or a static override, not
    `Platform.isWindows` deep inside.
- **Test:** `powershellQuote("a'b \$(rm x)")` must equal `'a''b $(rm x)'`. The Windows script built for a
  UTCP CLI tool must contain that quoted form.

### 4. The MCP port is busy, so the agents silently disappear
- **Where:** `lib/server/host_server.dart`, around `await m.start(...)` and
  `_mcp = null; // Port taken` (about lines 159–161).
- **Fix:** keep `String? mcpError` (for example "Port 8485 is in use by another program, so MCP
  tools and coding agents are off."). Clear it on start. Show it in `lib/features/host/host_screen.dart`
  (next to `host.error`) and in `lib/features/host/agents_card.dart`.
- **Test:** in `test/host_server_test.dart`, bind a `ServerSocket` on port P+1 first, start the host on P,
  and expect `mcpError != null` while the main API still answers `/health`.

### 5. An honest "Read only" label
- **Where:** `lib/features/host/agents_card.dart` (the `DropdownMenuItem` "Read only", about line 62) and the
  note under the folder list.
- **Fix:** change the text to "Read only (no file edits)". Add one line to the note:
  "Read only uses Claude Code's plan mode and Codex's read-only sandbox. Plan mode is a permission
  setting, not a full sandbox."
- **Test:** none needed (text only). `flutter analyze` must stay clean.

## Leave for later (write it down, don't fix now)
6. **The wrong device name can show on the approval box when two PCs ask at the same moment.**
   `HostServer._lastMcpDevice` (about line 82) is one shared field, because mcp_dart doesn't give tool
   callbacks the request. A proper fix needs per-session device mapping, and it belongs to the Lab
   Router "Clients" work (`docs/LAB_ROUTER_PLAN.md`, Phase 1).
7. **The PIN getter changes state while the screen is drawing.** `String get pin` in `host_server.dart`
   (about line 115) calls `newPin()`, which calls `notifyListeners()`. When the PIN expires while the host
   screen is open, this can throw "setState during build". Fix: rotate the PIN with a `Timer` in
   `start()` instead of inside the getter. Small; can be done after fixes 1–5.
8. The README still talks about the debug key and old test counts. Update it after the fixes.

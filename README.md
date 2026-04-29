# Tron

**A persistent, event-sourced AI coding agent for macOS.**

Tron is a local-first AI coding agent that runs as a persistent background service. A Rust server handles LLM communication, tool execution, and event-sourced session persistence. A native iOS app provides a real-time chat interface with streaming, session management, and push notifications.

This README is the single, canonical reference for the project and is expected to stay in sync with the code. The Rust codebase is self-documenting: `packages/agent/src/lib.rs` declares the module tree, `mod.rs` files map submodules, and `// INVARIANT:` comments mark critical correctness constraints. iOS documentation lives in `packages/ios-app/docs/`. When you change anything described here — modules, CLI commands, tools, RPC methods, event types, settings fields, DB tables, install layout — update this file in the same commit.

---

## Table of Contents

- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Rust Modules](#rust-modules)
- [Quick Start](#quick-start)
- [CLI Reference](#cli-reference)
- [Tools](#tools)
- [RPC API](#rpc-api)
- [Event System](#event-system)
- [Settings](#settings)
- [Authentication](#authentication)
- [Context and Compaction](#context-and-compaction)
- [Database Schema](#database-schema)
- [iOS App](#ios-app)
- [Mac App](#mac-app)
- [Permissions](#permissions)
- [Deployment](#deployment)
- [Testing](#testing)
- [Core Invariants](#core-invariants)

---

## Architecture

```
+-----------------------------------------------------------------------------+
|                              iOS App (SwiftUI)                              |
|                           packages/ios-app                                  |
|              MVVM  -  Coordinators  -  Event Plugins  -  Swift 6            |
+------------------------------------+----------------------------------------+
                                     | WebSocket (JSON-RPC 2.0)
                                     | Port 9847
                                     v
+-----------------------------------------------------------------------------+
|                          Rust Agent Server                                  |
|                         packages/agent                                      |
|                                                                             |
|  +-------------+  +-----------+  +------------+  +------------------------+ |
|  |  Providers  |  |   Tools   |  |  Context   |  |     Orchestrator       | |
|  |  Anthropic  |  | read/write|  |  loader    |  |  Session lifecycle     | |
|  |  OpenAI     |  | edit/bash |  |  compaction|  |  Turn management       | |
|  |  Google     |  | search/web|  |  skills    |  |  Event routing         | |
|  |  MiniMax    |  | subagents |  |  rules     |  |  Subagent coordination | |
|  +-------------+  +-----------+  +------------+  +------------------------+ |
+------------------------------------+----------------------------------------+
                                     |
                                     v
+-----------------------------------------------------------------------------+
|                         Event Store (SQLite)                                |
|   - Immutable event log with tree structure (fork/rewind)                   |
|   - Session state reconstruction via ancestor traversal                     |
|   - Full-text search (FTS5), task management (PARA)                         |
+-----------------------------------------------------------------------------+
```

### Data Path

1. Client sends JSON-RPC 2.0 over WebSocket
2. The `server` module dispatches to the appropriate RPC handler
3. Handlers call into runtime, orchestrator, and event store
4. Domain output is adapted at the boundary (`rpc/adapters.rs`) when iOS compatibility is required
5. Events and responses broadcast back through WebSocket channels

---

## Repository Structure

```
tron/
+-- VERSION.env             Canonical release version + Apple build source of truth
+-- packages/
|   +-- agent/              Rust agent server (single `tron` crate, modular layout)
|   +-- ios-app/            SwiftUI iOS application
|   +-- mac-app/            SwiftUI Mac menu-bar wrapper (Tron.app) — install wizard + server lifecycle
+-- scripts/
|   +-- tron                CLI for build, deploy, service management
|   +-- tron-version        Version print/check/sync helper used by CI + releases
|   +-- tron-lib.sh         Shared bash helpers used by scripts/tron
|   +-- tron-cli            Contributor CLI helper for local service management
|   +-- auto-deploy         Background auto-deploy worker (contributor-only; refuses to run outside a git repo)
+-- .github/
|   +-- workflows/          CI + Mac DMG release pipeline
|   +-- ISSUE_TEMPLATE/     Structured bug/feature report forms
|   +-- dependabot.yml      Weekly Cargo + GitHub Actions updates, monthly Swift
|   +-- pull_request_template.md
+-- .claude/
    +-- CLAUDE.md           AI agent project instructions
    +-- rules/              Path-scoped AI navigation rules
```

---

## Rust Modules

The agent is a single `tron` crate (see `packages/agent/Cargo.toml`). What used to be a multi-crate workspace was consolidated into one compilation unit; the modules below sit inside `packages/agent/src/` and are wired up in `lib.rs`. Dependencies flow top-down; no cycles.

```
core               Foundation: errors, IDs, paths, retry, text, content, ...
  |
  +-- settings         Settings schema, layered loading, global singleton
  +-- skills           SKILL.md parser, registry, context injection
  +-- transcription    Speech-to-text via parakeet-mlx Python sidecar (MLX backend)
  |
  +-- events           SQLite event store, migrations, reconstruction
  +-- import           Claude Code session import (parse → linearize → assemble → transform → write)
  +-- llm              Provider trait, model registry, SSE streaming, auth
  |     +-- anthropic/   Claude (OAuth + API key, cache pruning)
  |     +-- openai/      GPT/o-series (OAuth + API key)
  |     +-- google/      Gemini (Cloud Code Assist OAuth + API key)
  |     +-- minimax/     MiniMax (API key only)
  |     +-- kimi/        Kimi/Moonshot (API key only)
  |     +-- ollama/      Gemma 4 local inference (no auth, native /api/chat)
  +-- mcp              Model Context Protocol client/server bridge
  +-- tools            Tool trait, registry, tool implementations
  +-- cron             Scheduled job runner (automations)
  +-- prompt_library   Persistent prompt history + user-authored snippets
  +-- worktree         Git worktree management for isolated subagent runs
  |
  +-- runtime          Agent loop, context, hooks, orchestrator, tasks
  |
  +-- server           Axum HTTP/WS, RPC handlers, event bridge, APNS
  |                    +-- onboarding      Bearer token + `.onboarded` sentinel lifecycle
  |                    +-- websocket       WS upgrade handler + bearer-auth middleware
  |                    +-- updater         GitHub Releases poller + atomic self-update + rollback
  |
  +-- main.rs          Binary entry point: DB policy, CLI subcommands, startup
```

| Module | Purpose | Key Types |
|--------|---------|-----------|
| `core` | Shared vocabulary, paths, errors, message model | `Message`, `TronError`, `StreamEvent`, `TronEvent`, `SessionId`, `paths::*` |
| `settings` | Layered config (defaults + file + env) | `TronSettings`, `get_settings()`, `reload_settings_from_path()` |
| `skills` | Skill loading + injection | `SkillRegistry`, `process_prompt_for_skills()` |
| `transcription` | Speech-to-text via MLX sidecar | `MlxEngine`, `TranscriptionResult`, `TranscriptionError` |
| `events` | Event sourcing + SQLite | `EventStore`, `EventType`, `SessionEvent` |
| `import` | Claude Code session import | `import_session()`, `ImportResult`, `ClaudeProject`, `ClaudeSessionMeta` |
| `llm` | LLM abstraction + model registry | `Provider` trait, `ProviderFactory`, `ProviderStreamOptions` |
| `mcp` | Model Context Protocol integration | MCP client/server types |
| `tools` | Tool implementations | `TronTool` trait, `ToolRegistry`, per-tool structs |
| `cron` | Automation scheduler | Cron job runner, schedule parser |
| `prompt_library` | Prompt history + snippets (SQLite-backed) | `store::record_prompt`, `store::list_history`, `Snippet` |
| `worktree` | Git worktree isolation | Worktree create/cleanup helpers |
| `runtime` | Agent execution + orchestration | `TronAgent`, `Orchestrator`, `SessionManager`, `ContextManager` |
| `server` | HTTP/WS + RPC dispatch | `TronServer`, `MethodRegistry`, `RpcContext`, `EventBridge` |
| `server::onboarding` | Bearer token + first-run sentinel | `ensure_bearer_token()`, `touch_onboarded_sentinel()` |
| `server::websocket` | WS upgrade + bearer-auth middleware | `BearerAuth`, gated by `server.auth.enforced` |
| `server::updater` | Auto-update scheduler + installer | `Scheduler`, `UpdateAction`, `UpdateChannel`, `UpdateFrequency` |

---

## Quick Start

### End Users (recommended)

1. Install [Tailscale](https://tailscale.com) and sign in on the Mac that will host the agent.
2. Download the latest `Tron-mac-v*.dmg` from [GitHub Releases](https://github.com/mhismail3/tron/releases) and drag `Tron.app` into `/Applications`.
3. Launch `Tron.app`. The wizard handles Tailscale detection, required permissions, server install, and displays pairing info (Tailscale IP + port + bearer token + server name + QR code).
4. On iPhone, install the Tron TestFlight build. The app opens to the dashboard and presents a compact onboarding sheet; install/sign in to Tailscale on the phone, then scan the Mac pairing QR or enter the pairing fields manually.

The wizard and menu bar surface everything else (`Check for updates`, `Send feedback`, `Restart server`, etc.) — you never need the CLI unless you want to.

### Contributors (build from source)

Prerequisites:

- **Rust**: `rustup` + `cargo` (stable toolchain)
- **Xcode 16+** (for iOS + Mac apps)
- **XcodeGen**: `brew install xcodegen`

First-time setup:

```bash
./scripts/tron setup       # Check prerequisites, build, create ~/.tron/
./scripts/tron login       # Authenticate with Claude (OAuth browser flow)
```

Build and run:

```bash
# Build the server
cd packages/agent
cargo build --release

# Development mode (foreground, auto-rebuild)
./scripts/tron dev

# Or install as launchd service
./scripts/tron install
```

iOS app:

```bash
cd packages/ios-app
brew install xcodegen
xcodegen generate
open TronMobile.xcodeproj
```

Mac app wrapper (optional; for DMG development):

```bash
cd packages/mac-app
xcodegen generate
open TronMac.xcodeproj
```

Build with the `Tron` scheme (or `Tron Beta` for the beta variant). The app starts without a server until the user pairs a Mac through onboarding.

See [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, TDD expectations, and release workflows.

---

## CLI Reference

The `scripts/tron` CLI manages workspace development and contributor service workflows. The dispatch table is at the bottom of `scripts/tron` (the `case "$1" in` block); when adding or renaming a subcommand, update this table.

### Development (workspace only)

| Command | Description |
|---------|-------------|
| `tron dev` | Start the dev-profile server in the foreground (`-b` build first, `-t` test first, `-d` background). Stops the installed `com.tron.server` job before binding port `9847` and restores it through `/Applications/Tron.app` on exit. |
| `tron ci` | CI checks: any subset of `fmt`, `check`, `clippy`, `test`, `bench`, `doc` |
| `tron bench` | Performance benchmarks (`run`, `bless`, `compare`) |
| `tron version` | Central release version helper (`print`, `check`, `sync`, `bump`). `VERSION.env` is the only hand-edited release identity source; platform files are generated mirrors. |
| `tron setup` | First-time project setup |

### Deployment (workspace only)

| Command | Description |
|---------|-------------|
| `tron preflight` | Pre-deploy infrastructure check |
| `tron deploy` | Build, test, swap binary, restart, health-check (`--force` skips confirms; `--ci` is non-interactive) |
| `tron install` | Contributor-only shell install for workspace testing. The distributed Mac app does not call this; real installs use `/Applications/Tron.app` + `SMAppService`. |
| `tron uninstall [--reset-settings] [--reset-credentials]` | Remove launchd service/runtime bundles and reset Mac onboarding. Preserves the database and workspace; optional flags remove `settings.json` and/or `auth.json`. |
| `tron auto-deploy` | Contributor-only auto-deploy watcher (`install`, `uninstall`, `status`, `pause`, `resume`, `logs`). Refuses to run outside a git repo — for DMG users, see `tron self-update` instead. |
| `tron self-update` | User-mode GitHub Releases updater (`check`, `status`, `pause`, `resume`, `logs`, `reset`). Opt-in via `server.update.enabled`; gated by `~/.tron/auto-update.pause` sentinel. |

### Runtime

| Command | Description |
|---------|-------------|
| `tron start` | Start the launchd service (`com.tron.server`) |
| `tron stop` | Stop the service |
| `tron restart` | Restart the service |
| `tron status` | Show service status, PID, port |
| `tron rollback` | Restore the previous binary from backup (`--yes` skips confirm) |
| `tron login` | Authenticate with a provider (`--label <name>` for multi-account) |
| `tron auth rotate` | Rotate the WebSocket bearer token (forces every paired iOS device to pair again) |
| `tron logs` | Query database logs (`-h` for filter options) |
| `tron errors` | Show recent errors |

### Build Profiles

```bash
cd packages/agent
cargo check                        # Fast correctness check (no binary)
cargo build --profile dev-server   # Dev server (thin LTO, fast iteration)
cargo build --release              # Production (fat LTO, maximum optimization)
cargo test                         # Run the full test suite
cargo clippy -- -D warnings        # Lint with warnings as errors
```

---

## Tools

Tools are registered by `packages/agent/src/tool_factory.rs::create_tool_registry`, with subagent and job tools added in the `tool_factory` closure in `main.rs`. To add or rename a tool, update both files.

### Always-on (18)

| Tool | Description |
|------|-------------|
| `Read` | Read file contents with line numbers. Supports offset/limit for large files and PDF extraction. |
| `Write` | Write content to a file (creates or overwrites). |
| `Edit` | Search-and-replace within files (exact string matching, optional `replace_all`). |
| `Find` | Find files by glob pattern. |
| `Search` | Full-text content search built on ripgrep (regex, glob filters, multiple output modes). |
| `Bash` | Execute shell commands with configurable timeout. Supports backgrounding, blob storage for large output, and an optional sandbox image. |
| `AskUserQuestion` | Prompt the user for input with structured options. |
| `GetConfirmation` | Ask the user to confirm a high-stakes action before proceeding. |
| `NotifyApp` | Send a push notification to iOS through the Cloudflare relay, or use the stub delegate when relay config is absent. |
| `WebFetch` | Fetch and extract content from a URL. Uses an LLM subagent summarizer for large pages. |
| `WebSearch` | Search the web via the Brave Search API. Registered even before a Brave key exists; calls return a structured credential error until `services.brave` is set in `~/.tron/system/auth.json`. |
| `Display` | Render rich content (images, streams) for iOS clients via blob storage and `DisplayFrame` events. |
| `ComputerUse` | Screenshot, click, type, keypress, scroll, window management. |
| `McpSearch` | Meta-tool that searches across all configured MCP server tool catalogs by keyword. Registered with an empty result set when no MCP servers are configured. |
| `McpCall` | Meta-tool that invokes a specific tool on an MCP server. Registered even before MCP servers are configured, so later settings changes do not require a daemon restart. |
| `SpawnSubagent` | Spawn a child agent. Max depth controlled by `agent.subagent_max_depth` (default 3). |
| `ManageJob` | Inspect, signal, and clean up background jobs (Bash backgrounded processes + subagents). |
| `Wait` | Block until specified background jobs complete or hit a timeout. |

Source-control operations (sync main, push, switch branches, finalize a session into main, resolve merge conflicts) are driven by the user via the iOS Source Control sheet — the agent does not have typed git tools. When a session has a worktree, the agent is told (via a system-prompt block in `runtime/context/system_prompts::GIT_WORKFLOW_PROMPT`) that it can inspect state and make commits via `Bash git …` but must defer destructive / publishing operations to the user.

---

## RPC API

Tron RPC over WebSocket. The full registration list is in `packages/agent/src/server/rpc/handlers/mod.rs` (`register_core`, `register_capabilities`, `register_platform`) — that file is the source of truth. The current registration totals **165 methods** across three groups.

### Connection

```
WebSocket: ws://<host>:<port>/ws    Default port: 9847 (set via --port CLI flag)
Health:    GET  http://<host>:<port>/health
Metrics:   GET  http://<host>:<port>/metrics
```

Messages use the server's WebSocket RPC framing. Request IDs are strings and are echoed on responses:

```json
{"id":"ping-1","method":"system.ping"}
{"id":"ping-1","success":true,"result":{"pong":true,"timestamp":"…","serverVersion":"0.1.0","serverProtocolVersion":1,"minClientProtocolVersion":1,"compatible":true}}
```

`system.ping` requires `{"protocolVersion": <u32>, "clientVersion": <str>}` params. Clients that omit `protocolVersion` or send a non-numeric value receive `INVALID_PARAMS`; clients below `minClientProtocolVersion` receive `CLIENT_VERSION_UNSUPPORTED` with details naming both versions.

`system.getInfo` returns the running daemon's `version`, `uptime` (seconds), `activeSessions` count, `platform` / `arch`, plus three additive fields used by the iOS pairing flow:

- `port` — WebSocket listening port (mirrors the `--port` CLI flag).
- `tailscaleIp` — cached `server.tailscaleIp` from `settings.json`, or `null` if unset. The Mac pairing wizard resolves Tailscale live on fresh installs, then writes this cache for later wrapper/menu-bar reads and future server settings reloads.
- `paired` — `true` once `~/.tron/system/run/.onboarded` exists. The sentinel is touched by the Mac wizard at the end of its install flow OR on the first successful WS auth.

These fields are additive; older clients that ignore them continue to work unchanged.

`system.checkForUpdates` / `system.getUpdateStatus` drive user-mode GitHub Releases checks (see "Deployment → User-mode update checks"). Each has a deliberately tame default response so iOS + Mac menu-bar UIs render a meaningful empty state instead of a spurious error:

- `system.checkForUpdates` returns `{ available: false, disabled: true, channel, currentVersion }` when `server.update.enabled` is `false` (the safe default) — no GitHub fetch is performed.
- `system.getUpdateStatus` is a pure read of `settings.server.update` + `~/.tron/system/run/updater-state.json`; it always succeeds and exposes `enabled: false` plus null `latestAvailableVersion` for un-opted-in users.

### Core (63)

| Group | Count | Methods |
|-------|------:|---------|
| `system` | 6 | `system.ping`, `system.getInfo`, `system.getDiagnostics`, `system.shutdown`, `system.checkForUpdates`, `system.getUpdateStatus` |
| `blob` | 1 | `blob.get` |
| `session` | 13 | `session.create`, `session.resume`, `session.list`, `session.delete`, `session.fork`, `session.getHead`, `session.getState`, `session.getHistory`, `session.reconstruct`, `session.archive`, `session.unarchive`, `session.archiveOlderThan`, `session.export` |
| `agent` | 10 | `agent.prompt`, `agent.abort`, `agent.abortTool`, `agent.status`, `agent.queuePrompt`, `agent.dequeuePrompt`, `agent.clearQueue`, `agent.deliverSubagentResults`, `agent.submitConfirmation`, `agent.submitAnswers` |
| `model` / `config` | 3 | `model.list`, `model.switch`, `config.setReasoningLevel` |
| `context` | 8 | `context.getSnapshot`, `context.getDetailedSnapshot`, `context.shouldCompact`, `context.previewCompaction`, `context.confirmCompaction`, `context.canAcceptTurn`, `context.clear`, `context.compact` |
| `events` | 5 | `events.getHistory`, `events.getSince`, `events.subscribe`, `events.unsubscribe`, `events.append` |
| `settings` | 3 | `settings.get`, `settings.update`, `settings.resetToDefaults` |
| `auth` | 9 | `auth.get`, `auth.update`, `auth.clear`, `auth.oauthBegin`, `auth.oauthComplete`, `auth.renameAccount`, `auth.setActive`, `auth.removeAccount`, `auth.removeApiKey` |
| `tool` | 1 | `tool.result` |
| `message` | 1 | `message.delete` |
| `logs` | 2 | `logs.ingest`, `logs.recent` |
| `memory` | 1 | `memory.retain` |

### Capabilities (27)

| Group | Count | Methods |
|-------|------:|---------|
| `mcp` | 8 | `mcp.status`, `mcp.addServer`, `mcp.removeServer`, `mcp.enableServer`, `mcp.disableServer`, `mcp.restartServer`, `mcp.reload`, `mcp.listTools` |
| `skill` (registry) | 3 | `skill.list`, `skill.get`, `skill.refresh` |
| `skill` (session) | 3 | `skill.activate`, `skill.deactivate`, `skill.active` |
| `filesystem` | 4 | `filesystem.listDir`, `filesystem.getHome`, `filesystem.createDir`, `file.read` |
| `import` | 4 | `import.listSources`, `import.listSessions`, `import.previewSession`, `import.execute` |
| `tree` | 5 | `tree.getVisualization`, `tree.getBranches`, `tree.getSubtree`, `tree.getAncestors`, `tree.compareBranches` |

### Platform (75)

| Group | Count | Methods |
|-------|------:|---------|
| `browser` | 3 | `browser.startStream`, `browser.stopStream`, `browser.getStatus` |
| `display` | 1 | `display.stopStream` |
| `job` | 5 | `job.background`, `job.cancel`, `job.list`, `job.subscribe`, `job.unsubscribe` |
| `worktree` | 23 | `worktree.getStatus`, `worktree.isGitRepo`, `worktree.commit`, `worktree.merge`, `worktree.list`, `worktree.getDiff`, `worktree.acquire`, `worktree.release`, `worktree.listSessionBranches`, `worktree.getCommittedDiff`, `worktree.deleteBranch`, `worktree.pruneBranches`, `worktree.stageFiles`, `worktree.unstageFiles`, `worktree.discardFiles`, `worktree.finalizeSession`, `worktree.rebaseOnMain`, `worktree.startMerge`, `worktree.listConflicts`, `worktree.resolveConflict`, `worktree.continueMerge`, `worktree.abortMerge`, `worktree.resolveConflictsWithSubagent` |
| `transcribe` | 3 | `transcribe.audio`, `transcribe.listModels`, `transcribe.downloadModel` |
| `device` | 3 | `device.register`, `device.unregister`, `device.respond` |
| `plan` | 3 | `plan.enter`, `plan.exit`, `plan.getState` |
| `voiceNotes` | 3 | `voiceNotes.save`, `voiceNotes.list`, `voiceNotes.delete` |
| `git` | 5 | `git.clone`, `git.syncMain`, `git.push`, `git.listLocalBranches`, `git.listRemoteBranches` |
| `repo` | 2 | `repo.listSessions`, `repo.getDivergence` |
| `sandbox` | 5 | `sandbox.listContainers`, `sandbox.startContainer`, `sandbox.stopContainer`, `sandbox.killContainer`, `sandbox.removeContainer` |
| `notifications` | 3 | `notifications.list`, `notifications.markRead`, `notifications.markAllRead` |
| `promptHistory` | 3 | `promptHistory.list`, `promptHistory.delete`, `promptHistory.clear` |
| `promptSnippet` | 5 | `promptSnippet.list`, `promptSnippet.get`, `promptSnippet.create`, `promptSnippet.update`, `promptSnippet.delete` |
| `cron` | 8 | `cron.list`, `cron.get`, `cron.create`, `cron.update`, `cron.delete`, `cron.run`, `cron.status`, `cron.getRuns` |

---

## Event System

The event store uses an immutable, append-only log with **80 typed event variants**. Sessions are tree-structured, supporting fork and rewind. State is always reconstructed from events; no mutable session state is stored outside the log.

The canonical event list is generated by the `define_events!` macro in `packages/agent/src/events/types/macros.rs`, invoked from `events/types/generated.rs`. Adding a new event means editing `generated.rs` and adding a payload type — the macro generates the `EventType` enum, wire-format helpers, and `ALL_EVENT_TYPES` automatically.

### Event Categories

| Domain | Events |
|--------|--------|
| `session` | `session.start`, `session.end`, `session.fork` |
| `message` | `message.user`, `message.assistant`, `message.system`, `message.deleted`, `message.queued`, `message.dequeued` |
| `tool` | `tool.call`, `tool.result`, `tool.progress` |
| `stream` | `stream.text_delta`, `stream.thinking_delta`, `stream.turn_start`, `stream.turn_end` |
| `config` | `config.model_switch`, `config.prompt_update`, `config.reasoning_level` |
| `notification` | `notification.interrupted`, `notification.subagent_result`, `notification.process_result`, `notification.user_job_action` |
| `compact` | `compact.boundary`, `compact.summary`, `compact.summary_staging` |
| `context` | `context.cleared` |
| `skill` | `skill.activated`, `skill.deactivated`, `skills.cleared` |
| `rules` | `rules.loaded`, `rules.indexed`, `rules.activated` |
| `metadata` | `metadata.update`, `metadata.tag` |
| `file` | `file.read`, `file.write`, `file.edit` |
| `worktree` | `worktree.acquired`, `worktree.commit`, `worktree.released`, `worktree.merged`, `worktree.renamed`, `worktree.main_synced`, `worktree.session_finalized`, `worktree.merge_started`, `worktree.conflict_detected`, `worktree.conflict_resolved`, `worktree.merge_continued`, `worktree.merge_aborted`, `worktree.pushed`, `worktree.pending_merge_detected`, `worktree.rebased_on_main`, `worktree.post_rebase_stash_conflict`, `worktree.auto_recovered_commits` |
| `repo` | `repo.lock_acquired`, `repo.lock_released`, `repo.main_advanced` |
| `error` | `error.agent`, `error.tool`, `error.provider` |
| `subagent` | `subagent.spawned`, `subagent.status_update`, `subagent.completed`, `subagent.failed`, `subagent.results_consumed` |
| `process` / `user_job_actions` | `process.results_consumed`, `user_job_actions.consumed` |
| `todo` / `turn` | `todo.write`, `turn.failed` |
| `hook` | `hook.triggered`, `hook.completed`, `hook.background_started`, `hook.background_completed`, `hook.llm_result` |
| `memory` | `memory.retained`, `memory.auto_retain_triggered`, `memory.auto_retain_failed` |
| `device` | `device.token_invalidated` |
| `server.update` | `server.update_available` |

### Event Broadcasting

Events flow from the agent through a broadcast channel to all connected WebSocket clients:

```
TronAgent (run loop)  ->  EventEmitter  ->  Orchestrator broadcast
                                                    |
EventBridge  <------------------------------------------+
    |
    v
BroadcastManager  ->  Per-connection WebSocket writers
```

The `EventBridge` also routes browser CDP frames and `Display` tool frames when iOS clients are subscribed.

---

## Settings

**Location:** `~/.tron/system/settings.json`

Settings are loaded from three layers (highest priority last):

1. **Compiled defaults** (`TronSettings::default()`)
2. **User file** (`~/.tron/system/settings.json`, deep-merged over defaults)
3. **Environment variables** (`TRON_*` overrides)

Settings are server-authoritative. The iOS app reads the effective merged values via `settings.get` and writes sparse user overrides via `settings.update` / `settings.resetToDefaults`. When settings are updated, the server atomically swaps its cached `Arc<TronSettings>`.

`settings.json` is intentionally sparse and high-signal: it stores only values the user/app explicitly changed. Built-in defaults stay in `TronSettings::default()` and appear in `settings.get` after the user file is deep-merged over them. iOS device-only preferences live in iOS storage/Keychain, not in the server settings file.

The schema is defined in `packages/agent/src/settings/types/`. All field names are camelCase on the wire. **The WebSocket port is a CLI flag (`--port`, default 9847), not a settings field.**

### Key Configuration

```jsonc
{
  "version": "0.1.0",
  "name": "tron",

  "server": {
    "heartbeatIntervalMs": 30000,
    "defaultProvider": "anthropic",
    "defaultModel": "claude-sonnet-4-6",
    "defaultWorkspace": null,       // Optional quick-chat workspace path set by iOS onboarding/settings
    "transcription": { "enabled": false },
    "tailscaleIp": null,            // Cached by the Mac wrapper after live Tailscale pairing resolution
    "auth": {
      "enforced": false             // When true, every WS upgrade requires a paired-device bearer token
    },
    "update": {                     // User-mode update checks. All fields off / safest by default.
      "enabled": false,             // Master switch — false means the scheduler never runs + no GitHub API traffic
      "channel": "stable",          // "stable" ignores pre-release tags; "beta" includes them
      "frequency": "daily",         // "manual" | "startup" | "hourly" | "daily" | "weekly"
      "action": "notify"            // notify-only; installing remains DMG replacement
    }
    // NB: telemetry is an iOS-only opt-in stored under `@AppStorage("telemetryEnabled")`;
    // no corresponding server setting exists because the server never emits telemetry.
  },

  "agent": {
    "maxTurns": 250,
    "subagentMaxDepth": 3,
    "subagentModel": "claude-haiku-4-5-20251001"
  },

  "context": {
    "compactor": {
      "maxTokens": 25000,           // Context budget
      "compactionThreshold": 0.85,  // Hard ceiling that triggers compaction
      "targetTokens": 10000,        // Target token count after compaction
      "charsPerToken": 4,           // Token estimation factor
      "bufferTokens": 4000,         // Response buffer
      "triggerTokenThreshold": 0.70,// Soft threshold for proactive compaction (also used as preserved-turn budget)
      "preserveRecentCount": 5      // Always preserve N most recent messages
    },
    "rules": {
      "discoverStandaloneFiles": true  // Pick up AGENTS.md / CLAUDE.md outside .claude/rules/
    }
  },

  "tools": {
    "bash": { "defaultTimeoutMs": 120000 }
  },

  "skills": {
    "compactionPolicy": "clearAll",   // "clearAll" | "autoRestore" | "askUser"
    "showIndex": "always"             // "always" | "never" | "whenNoActiveSkills"
  },

  "memory": {
    "autoRetainInterval": 10,                   // Turns between auto-retentions. 0 disables.
    "retainModel": "claude-sonnet-4-6"          // Model used by the retain summarizer subagent.
  },

  "retry":  { "maxRetries": 1 },
  "hooks":  { "defaultTimeoutMs": 5000, "discoveryTimeoutMs": 10000, "extensions": [".ts", ".js", ".mjs", ".sh"] },

  "promptLibrary": {
    "historyEnabled": true,         // Auto-save interactive prompts to history
    "historyMaxEntries": 10000,     // 0 = unlimited
    "historyMaxAgeDays": 0,         // 0 = unlimited
    "historyAutoPrune": true        // Opportunistic pruning on record + startup
  },

  "git": {
    "targetBranch": null,                       // null → auto-detect via init.defaultBranch / main / master
    "protectedBranches": ["main", "master", "develop"],
    "sessionBranchPolicy": "keep",              // "keep" | "deleteOnFinalize"
    "mergeStrategy": "merge",                   // "merge" | "rebase" | "squash"
    "autoSetUpstream": true,
    "crashRecoveryAbortTimeoutMs": 1800000,     // 30 min — auto-abort a pending merge recovered at startup
    "opTimeoutNetworkMs": 60000,                // Timeout for fetch / push / ls-remote
    "opTimeoutLocalMs": 30000,                  // Timeout for local git ops
    "subagentConflictResolutionEnabled": true   // Spawn a child subagent to resolve merge conflicts
  },

  "mcp": {
    "servers": [],                              // MCP server configs
    "schemaRefreshTtlMs": 30000                 // Proactive schema re-fetch TTL. 0 disables.
  }
}
```

---

## Authentication

**Storage:** `~/.tron/system/auth.json` (mode 600)

The auth system supports OAuth 2.0 (PKCE), API keys, and multi-account selection. OAuth tokens auto-refresh before expiry. The schema is defined in `packages/agent/src/llm/auth/types.rs` (`AuthStorage` → per-provider `accounts` + `apiKeys` + `activeCredential`).

### Providers

| Provider | Module | Auth Methods | Notes |
|----------|--------|--------------|-------|
| Anthropic | `llm/anthropic/` | OAuth (primary), API key | PKCE OAuth flow; cache pruning supported |
| OpenAI    | `llm/openai/`    | OAuth, API key            | Codex CLI compatibility |
| Google    | `llm/google/`    | OAuth, API key            | Cloud Code Assist OAuth, Gemini API key |
| MiniMax   | `llm/minimax/`   | API key only              | — |
| Kimi      | `llm/kimi/`      | API key only              | — |
| Ollama    | `llm/ollama/`    | None (local)              | Requires Ollama running locally on the same Mac as the agent |

### Multi-Account

```bash
tron login --label work
tron login --label personal
```

`auth.json` stores accounts under `providers.<name>.accounts[]` (named OAuth entries) and `providers.<name>.apiKeys[]` (named API keys). The active credential per provider is selected by `providers.<name>.activeCredential`, which is `{type: "oauth"|"apiKey", label}`. Manage from the iOS app or via `auth.*` RPC methods. When an API key is saved without a custom label, Tron stores it as `Default`.

### Auth Precedence

1. The provider's `activeCredential` from `auth.json` (OAuth or API key, by label)
2. The provider's first non-active OAuth account
3. The provider's first non-active API key
4. Environment variable fallback (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`)

### WebSocket Bearer Token

**Storage:** `~/.tron/system/auth.json` top-level `bearerToken` (mode 600, atomic writes)

Stored beside provider auth in the same secure file. This single 32-byte URL-safe-base64 token gates every WebSocket upgrade request when `server.auth.enforced` is `true`. The same token is shared across all paired iOS devices for a given server (per-device tokens are deferred to a future version).

The token is generated during first server startup and written as `bearerToken` inside `~/.tron/system/auth.json`. The Mac onboarding wizard and iOS pairing flow both display it for the user to copy into the iOS pairing step.

```bash
# Rotate the token (forces every paired iOS device to pair again)
tron auth rotate

# Then use iOS Settings → Servers → Connect to a new server to scan or paste a fresh token.
```

Rotation is serialized through a process-wide mutex and the on-disk write is atomic (`tempfile + sync_all + rename`), so a concurrent rotate from the menu bar and CLI cannot corrupt the file. After rotation the daemon's in-memory token cache picks up the new value within a few seconds via mtime comparison; iOS clients carrying the old token receive HTTP 401 on next connect and fall into `ConnectionState.unauthorized`.

The first-run sentinel `~/.tron/system/run/.onboarded` is created by the Mac wizard at the end of its install flow OR on the first successful WS auth, and is reported to iOS via the `paired` field of `system.getInfo` (so an iOS device pointed at a fresh server can distinguish "never been onboarded" from "ready to pair").

See [`packages/agent/src/server/onboarding/mod.rs`](packages/agent/src/server/onboarding/mod.rs) for the full token + sentinel lifecycle.

---

## Context and Compaction

The context system manages the LLM's input window. Each turn assembles: system prompt + rules + skills + conversation history + tool results.

### Compaction Pipeline

When context approaches the token budget (default `compactionThreshold: 0.85` of `maxTokens`), compaction triggers:

1. **Summarize**: A subagent condenses older messages into a summary.
2. **Boundary**: A `compact.boundary` event marks the cutoff point in the event log.
3. **Trim**: Messages before the boundary are replaced with the summary on reconstruction.
4. **Preserve recent**: The most recent `preserveRecentCount` messages always survive the cut.

Compaction is observable via `context.shouldCompact`, `context.previewCompaction`, and `context.confirmCompaction` RPC methods. Programmatic compaction is exposed via `context.compact`.

### Context Assembly Order

```
System prompt    (stable, per-model)
  + Rules        (path-scoped from .claude/rules/, project-relative AGENTS.md / CLAUDE.md)
  + Skills       (@skill references from prompt + always-on skills)
  + History      (messages since the most recent compaction boundary)
  + Pending      (current user prompt + tool results)
```

### Skills

Reusable context packages stored as `SKILL.md` files with optional YAML frontmatter.

**Locations** — scanned across every service folder in `SKILL_SERVICE_DIRS` (currently `tron`, `claude`):
- `~/.tron/skills/`, `~/.claude/skills/` — Global (all projects). First-party skills under `packages/agent/skills/` are bundled into the Mac app at `Contents/Resources/Skills/` and synced into `~/.tron/skills/` by the Mac installer/menu-bar start path, `tron dev`, and `tron install`. Managed skills carry a `.managed` sentinel file; user-owned same-name directories are preserved. `~/.claude/skills/` is read-only to Tron (Claude Code owns that tree) but its contents are detected automatically.
- `.tron/skills/` or `.claude/skills/` under the working directory (any depth) — Project-local (higher precedence than globals). `.tron/skills/` wins over `.claude/skills/` on same-name collision within a single scope.

**Usage:** Reference with `@skill-name` in prompts. The injector extracts references, resolves them from the registry, and prepends the skill content as `<skills>` XML context. Session-scoped activation is also exposed via `skill.activate` / `skill.deactivate` RPC methods.

### Hooks

Async lifecycle hooks execute before/after tool calls and around prompts:

- **Discovery:** `.agent/hooks/` (project), `~/.config/tron/hooks/` (global)
- **Extensions:** configurable via `hooks.extensions` (default `.ts`, `.js`, `.mjs`, `.sh`)
- **Background hooks:** drained before accepting a new prompt and before session reconstruction (see Core Invariant #7)

---

## Database Schema

All data lives in a single SQLite file: `~/.tron/system/database/log.db`. WAL mode with 5 s busy timeout for concurrent access. The schema is a single consolidated migration, `packages/agent/src/events/sqlite/migrations/v001_schema.sql`, registered in `migrations/mod.rs` (the source of truth for schema versioning). Every constraint is declared inline on `CREATE TABLE`: `UNIQUE(session_id, sequence)` on events, `CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)` on events, `CHECK (use_worktree IS NULL OR use_worktree IN (0, 1))` on sessions, and a `COALESCE`-nullable unique index on `device_tokens (device_token, platform, workspace_id, bundle_id)` so the same APNs push token can register across multiple workspaces or bundles without clobbering. There is no migration chain to replay — the project's policy is "develop against v001, delete `~/.tron/system/database/log.db` when the schema changes before release, add v002+ only after the first release." The runner verifies each applied migration with `PRAGMA foreign_key_check` and refuses to commit if any dangling reference would be left behind.

### Tables

| Table | Purpose |
|-------|---------|
| `schema_version` | Migration version tracking |
| `workspaces` | Project/directory contexts (id, path, name, timestamps) |
| `sessions` | Session metadata: head pointer, title, model, token counts, tags, fork lineage, spawn metadata, optional `use_worktree` per-session worktree override |
| `events` | Immutable append-only event log. Denormalized columns (`role`, `tool_name`, `tool_call_id`, `turn`, token counts, `model`, `latency_ms`, `stop_reason`, `provider_type`, `cost`, ...) extracted from payloads for indexed queries |
| `blobs` | Content-addressable deduplicated storage (hash, compressed content, MIME type, ref count) |
| `branches` | Named positions in the event tree (root + head pointer per branch) |
| `logs` | Application logs (level, component, message, error fields, trace IDs, origin) |
| `device_tokens` | iOS push notification tokens — identity is `(device_token, platform, workspace_id, bundle_id)` (COALESCE-nullable unique index collapses NULL workspace/bundle to a single canonical row; `bundle_id` lets the relay send Beta-scheme tokens to the correct APNs topic) |
| `notification_read_state` | Per-event read receipts for client notifications |
| `cron_jobs` | Cron job definitions: schedule, payload, delivery, overlap/misfire policies, runtime state (next/last run, consecutive failures) |
| `cron_runs` | Per-run history for cron jobs (status, started/completed timestamps, output, exit code) |
| `prompt_history` | Deduplicated interactive-prompt history keyed by normalized text hash (use_count, first/last_used_at, char_count) |
| `prompt_snippets` | User-authored reusable prompt snippets (`name`, `text`, timestamps) |

The events table enforces correctness with `UNIQUE(session_id, sequence)` and a single ordering index on `(session_id, sequence)` — most other access patterns are intentionally allowed to scan/filter at our volumes. There are no FTS5 virtual tables, and there is no PARA-style task table — task management is overlaid on the event log via tools.

---

## iOS App

**Minimum iOS:** 18.0 | **Swift:** 6.0 | **Build system:** XcodeGen

### Architecture

The app uses MVVM with coordinators, event plugins, and SwiftUI's `@Observable` macro. The authoritative architecture document is `packages/ios-app/docs/architecture.md`.

```
packages/ios-app/Sources/
+-- App/                  App entry point, delegates, scene phases
+-- Core/                 DI, EventDispatchCoordinator, plugins, payloads
+-- Database/             SQLite event database, queries
+-- Models/               Data models, RPC codables, event types
+-- Protocols/            Coordinator and view model protocols
+-- Services/             Network (RPC client, WebSocket, deep links), paired servers, audio,
+                         push notifications, feedback composer, telemetry redactor, Keychain tokens
+-- ViewModels/           Chat view models, handlers, managers, @Observable state, OnboardingState
+-- Views/                SwiftUI views (chat, tools, voice notes, settings, Onboarding/, ...)
+-- Theme/                Colors, typography, design tokens
+-- Utilities/            Shared helpers
+-- Extensions/           Type extensions
+-- Resources/            Localized strings, fixtures
+-- Assets.xcassets/      Icons and images
+-- IconLayers/           Source layers for the app icon
+-- Info.plist            App metadata
+-- PrivacyInfo.xcprivacy Apple privacy manifest
```

### Key Patterns

- **MVVM + Extensions**: Large view models split across extension files (`ChatViewModel+Connection.swift`, etc.)
- **Coordinator pattern**: Stateless logic in coordinators, state in view models via context protocols
- **Event plugins**: Live WebSocket events parsed by plugins, dispatched by `EventDispatchCoordinator`
- **History transformer**: Stored events reconstructed into `ChatMessage` arrays by `UnifiedEventTransformer`
- **Dependency injection**: All services via SwiftUI `@Environment(\.dependencies)`
- **Onboarding sheet**: `TronMobileApp.readyContent()` always mounts `ContentView`; when `@AppStorage("onboardingComplete")` is false it presents `OnboardingFlowView`. Settings can reopen the same flow at the Connect page for another server or token refresh, with a dismiss button. New-server onboarding requires a scanned/pasted/manual token before Connect is enabled; an already paired server row can reuse that server's Keychain token unless the user edits its host or port. Setup pages are not available until a pairing probe, `settings.get`, and setup hydration succeed.
- **Local paired-server model**: `PairedServerStore` keeps the paired Mac list and active server id in iOS storage, while `PairedServerTokenStore` stores each server's bearer token in Keychain. The server never stores the iOS pair list in `settings.json`.
- **Setup hydration**: after QR/manual pairing, onboarding reads the active Mac's `settings.get` response and best-effort `auth.get` masked credential state before unlocking setup pages. Pairing a previously forgotten Mac therefore shows the server's existing workspace/model choices and credential hints without storing server settings or secrets on iOS; OAuth/API-key saves refresh those cards immediately from the returned `AuthState`.
- **Forgetting a server**: Settings → Servers → menu → "Forget" removes the server and token locally. If another paired server remains, the app switches locally; if none remain, Settings shows the onboarding CTA.
- **Telemetry + feedback**: `SentryRedactor` scrubs bearer tokens, file paths, and chat content before crash events leave the device. `FeedbackComposer` builds a redacted log tail and opens a prefilled GitHub issue instead of launching Mail. Opt-in toggle on the Privacy settings page stores to `@AppStorage("telemetryEnabled")` (default OFF).

### Data Flow

```
Live:    WebSocket -> RPCClient -> EventRegistry -> Plugin -> EventDispatchCoordinator -> ChatViewModel
Stored:  EventDatabase -> UnifiedEventTransformer -> [ChatMessage] -> ChatViewModel -> ChatView
```

### Build Configurations

| Config | Use |
|--------|-----|
| Beta | Debug build, side-by-side bundle ID |
| Prod | Release build, production bundle ID |

### Documentation

Detailed iOS documentation lives in `packages/ios-app/docs/`:

- `architecture.md` — App architecture, patterns, file placement
- `development.md` — Xcode setup, builds, testing
- `events.md` — Event plugin system
- `apns.md` — Push notification setup
- `onboarding.md` — First-run onboarding sheet, QR/deep-link handling, local paired servers, and bearer persistence

---

## Mac App

**Minimum macOS:** 15 Sequoia | **Swift:** 6.0 | **Bundle ID:** `com.tron.mac` | **Build system:** XcodeGen

`Tron.app` is a SwiftUI wrapper around the headless Rust agent. It ships as a notarized DMG via `.github/workflows/release-mac.yml`; production installs run only from `/Applications/Tron.app`. The app bundles a signed helper at `Contents/Library/LoginItems/Tron Server.app`, a bundled LaunchAgent plist, managed skills under `Contents/Resources/Skills/`, and the small transcription sidecar source files under `Contents/Resources/Transcription/`. The wizard registers the helper through `SMAppService`, syncs bundled managed skills into `~/.tron/skills/`, confirms permissions, optionally enables local transcription, and reveals pairing info for iOS. After the wizard, the app transforms into a menu-bar icon (`LSUIElement = YES`) that polls `system.ping` every 30s.

```
packages/mac-app/Sources/
+-- TronMacApp.swift           App entry: branches on ~/.tron/system/run/.onboarded sentinel
+-- EnvironmentSetup.swift     Dev vs release bundle-ID wiring, log paths, shared state root
+-- Wizard/                    First-run flow
|   +-- WizardState.swift      @Observable state machine + `WizardStep` enum
|   +-- WizardView.swift       NavigationStack shell
|   +-- Steps/                 Welcome, Tailscale, Install, Permissions, Transcription, Pairing, Done
+-- MenuBar/                   NSStatusItem controller, status polling, copy actions, update submenu
+-- Services/
|   +-- Server/                Bearer-token reader, `system.ping` client, status poller
|   +-- Onboarding/            SMAppService install planner, permission/Tailscale probes, existing-install detection
|   +-- Pairing/               Tailscale live probe + auth.json bearer-token reader; QR + tron:// URL generation
|   +-- Feedback/              GitHub issue composer with redacted log context
|   +-- Observability/         SentryRedactor (shared pattern with iOS)
|   +-- LaunchAgentManaging.swift
|   +-- TronPaths.swift        ~/.tron/ path helpers (mirrors Rust `core::foundation::paths`)
+-- Resources/
    +-- Transcription/worker.py + requirements.txt
    +-- Library/
        +-- LoginItems/Tron Server.app/Contents/MacOS/tron
        +-- LaunchAgents/com.tron.server.plist
```

### Wizard Steps

1. **Welcome** — introduces Tron.
2. **Tailscale prerequisite** — detects `/Applications/Tailscale.app` or the Tailscale CLI, then reads `tailscale status --peers=false --json` for a running backend and 100.x IPv4.
3. **Install** — detects whether the bundled Login Item is registered, but treats that as registered-not-ready until the user presses Install/Start and `system.ping` answers. It validates that release builds are running from `/Applications/Tron.app`, validates the helper/plist/signature, registers or refreshes `com.tron.server` through `SMAppService`, handles `requiresApproval` by opening Login Items settings, and polls `system.ping` while ignoring initial `connection.established` frames.
4. **Permissions** — Full Disk Access, Screen Recording, and Accessibility. Deep-links to System Settings, labels the exact app entry to enable for each permission, polls wrapper-owned TCC state, starts a short-lived fast-probe watcher after wizard-opened Settings panes, and keeps Re-check as a non-restarting probe.
5. **Transcription** — opt-in step for local voice transcription. The step copies `worker.py` and `requirements.txt` from the signed app bundle into `~/.tron/system/transcription/` so the setting can be enabled later. Enabling writes `server.transcription.enabled = true`, restarts the helper once, and lets the Parakeet model download into `~/.tron/system/transcription/models/hf/` when the sidecar starts. Skipping writes `enabled = false` and does not restart the server.
6. **Pairing** — reads the agent-issued bearer token, confirms the local server heartbeat, resolves this Mac's Tailscale IP live (then caches it to `settings.json`), detects the Mac's user-facing computer name, and displays host + port + token + server name with copy buttons and a QR code encoding `tron://pair?host=<ip>&port=<port>&token=<token>&label=<server-name>`.
7. **Done** — touches `.onboarded` sentinel, transforms to menu-bar mode.

### Menu-bar Actions

| Item | Action |
|------|--------|
| Custom status header | Shows `Tron`, the Tailscale endpoint, color-coded state, PID, live uptime, and a `Dev Server active` marker when `tron dev` owns port 9847 |
| Show pairing info | Opens a pairing-only window with QR + manual copy buttons for host, port, token, and server name; copy actions quickly show a checkmark for two seconds on success |
| Restart / Pause / Resume server | `launchctl kickstart` for restart diagnostics, `SMAppService.unregister/register` for stop/start, shows busy state and posts success/failure notifications |
| Stop dev server | Appears in the bottom developer section whenever `Tron-Dev.app` owns port 9847, even while developer options are collapsed; stops the dev process and resumes the installed Login Item. Pause, restart, and uninstall are disabled while dev takeover is active. |
| Developer options | A collapsed bottom section exposes `Show Developer Options`; when expanded it runs background-safe `scripts/tron dev -d`, `scripts/tron dev -td`, and `scripts/tron dev -btd` commands from the checkout resolved by `TRON_PROJECT_ROOT` or a nearby source tree |
| Show logs | Opens the native logs window backed by the read-only `logs.recent` RPC |
| Send feedback | Opens a prefilled GitHub issue with app/server context and redacted recent logs |
| Check for updates | Opens the latest GitHub Release |
| Uninstall Tron | Confirm dialog + `SMAppService.unregister`; clears `system/run/` runtime state; optional checkboxes remove `settings.json` and/or `auth.json`. The database and workspace are always preserved. |
| Quit Tron | Quits wrapper; server keeps running via LaunchAgent |

### Variants & Workflows

The wrapper coexists with local Release testing, Xcode Debug dogfood, and the `tron dev` agent-only workflow. Four workflows share `port 9847` and the `~/.tron/system/` data tree:

| Workflow | Build product | Bundle ID | Lives at | What it is |
|---|---|---|---|---|
| **Production (DMG)** | `Tron.app` | `com.tron.mac` | `/Applications/Tron.app` | Notarized SwiftUI wrapper + bundled headless agent — what end users install |
| **Local Release test** (Xcode Release copied into place) | `Tron.app` | `com.tron.mac` | `/Applications/Tron.app` | Same installed-release path as the DMG; useful for validating local changes before packaging |
| **Wizard dogfood** (Xcode Run / `xcodebuild -configuration Debug`) | `TronMac.app` | `com.tron.mac.dev` | `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/TronMac.app` | Same SwiftUI wrapper, debug-profile bundled agent — used by contributors testing the UI |
| **Agent dev** (`tron dev`) | `Tron-Dev.app` (no SwiftUI — just a `.app` wrapping the dev Rust binary) | `com.tron.agent` | `~/.tron/system/run/Tron-Dev.app` | Headless agent only — used by contributors iterating on the Rust server without rebuilding the wrapper |

Mutual exclusion:
- Multiple wrappers (workflows 1/2/3) — guarded by `~/.tron/system/run/.mac-wrapper.lock` (`fcntl(F_SETLK, F_WRLCK)`); any second instance terminates.
- Two agents — guarded by `~/.tron/system/database/log.db.lock` (cross-process exclusive `flock`).
- LaunchAgent ownership — Debug wrapper builds (`com.tron.mac.dev`) outrank installed-release wrappers for contributor dogfood and may stop a lower-priority loaded job before registering their bundled helper. Installed-release wrappers do not take over from a running Debug wrapper.
- Port `9847` — `tron dev` calls `launchctl bootout com.tron.server` before binding, so the installed helper is paused while dev-mode runs.
- Direct server guard — if no LaunchAgent owns the service but port `9847` is already bound or `system/database/log.db.lock` is held, the app reports another Tron server instead of registering a second helper or choosing a different port.

A contributor can have the DMG installed AND switch to `tron dev` for agent iteration without uninstalling — the wrapper's menu bar keeps pinging port 9847, reports the `Tron-Dev.app` PID/uptime, and shows `Dev Server active` while dev owns the port. Quitting `tron dev` restarts the installed helper by invoking `/Applications/Tron.app/Contents/MacOS/Tron --tron-start-server-and-quit`, which re-enters the same `SMAppService` registration path used by the app. Pre-onboarding/debug cleanup uses the paired internal command `--tron-uninstall-and-quit` so stale Login Item registrations are removed by `SMAppService.unregister` instead of only being booted out of launchd. See [`packages/mac-app/docs/architecture.md` → Workflows & Variants](packages/mac-app/docs/architecture.md#workflows--variants) for the full breakdown including the on-disk artifacts each workflow shares.

### Documentation

- `packages/mac-app/docs/architecture.md` — wizard + menu bar + helper-binary lifecycle
- `packages/mac-app/docs/development.md` — workflow quick reference for Xcode Debug, local Release install testing, `tron dev`, and DMG release, plus XcodeGen/signing setup

---

## Permissions

The Mac wizard surfaces three system permissions after the server is installed. Each permission has an "Open System Settings" deep link when revoked, and each row names the exact app entry macOS expects in that pane.

| Permission | Why | Required | Probe |
|------------|-----|----------|-------|
| Full Disk Access | Agent reads/writes user-selected files and app data outside the sandbox | Yes | Wrapper process opens FDA-gated user data |
| Screen Recording | ComputerUse screenshots and visual inspection | Yes | Wrapper `CGPreflightScreenCaptureAccess()` plus a fresh wrapper probe process |
| Accessibility | ComputerUse mouse/keyboard control | Yes | `AXIsProcessTrusted()` in the wrapper |

The install step validates the signed `Tron Server.app`, registers the bundled LaunchAgent through `SMAppService`, and waits for the first heartbeat. Ordinary agent startup does not probe TCC or open System Settings, so macOS permission prompts cannot appear while the user is still on the install step. The LaunchAgent's `AssociatedBundleIdentifiers` lists the wrapper bundle IDs, so macOS presents the helper's privacy grants under the responsible wrapper app: `Tron.app` in Release and `TronMac.app` in Debug. All three wizard rows therefore name the wrapper app, not `Tron Server.app`. The settings buttons only open System Settings; they never call prompt APIs that would create a second modal over the already-open pane. Screen Recording additionally shows a small draggable wrapper-app icon for the macOS case where the row is not inserted automatically; the row copy tells the user to drag that icon into the list. Re-check/app activation use native non-prompting probes. Screen Recording probes the current wrapper first; if macOS still reports the current process as stale after a Settings change, the wizard starts the same wrapper executable once as a quiet child probe and reads that fresh process result from `~/.tron/system/run/`. Once all three rows are green, Continue restarts the helper one time so launch-time-applied grants are visible to the server before pairing.

---

## Deployment

### Deploy Pipeline

```bash
tron deploy          # Full pipeline with confirmations
tron deploy --force  # Skip uncommitted-changes / test-failure prompts
tron deploy --ci     # Non-interactive: any failure aborts
```

`tron deploy` is a contributor-only script path and is not the production Mac distribution mechanism. Production releases are the notarized DMG pipeline below; end users replace `/Applications/Tron.app` from that DMG.

The deploy process (`scripts/tron::cmd_deploy`) is retained for local contributor workflows:

1. Aborts if a dev server is bound to the prod port.
2. Warns on uncommitted changes (errors out under `--ci`).
3. Builds the release binary (`cargo build --release`).
4. Runs `cargo test`. Failures prompt for continuation unless `--ci`.
5. Under `--ci`, also runs the benchmark gate.
6. Uses contributor-only artifacts directly under `~/.tron/system/run/`.
7. Syncs managed skills and transcription support.
8. Runs local health checks for the contributor server.

### Install Directory

All paths in the tree below are resolved through helpers in `packages/agent/src/core/foundation/paths.rs`. To rename a directory, change the constant in `dirs::*` there and every call site updates automatically.

```
~/.tron/
+-- skills/                       Global skills (SKILL.md files); managed entries have a .managed sentinel
+-- system/
|   +-- settings.json             Sparse user settings overrides (optional; deep-merged over compiled defaults)
|   +-- auth.json                 LLM provider OAuth tokens + API keys + bearerToken (mode 600)
|   +-- database/                 SQLite event store
|   |   +-- log.db                Events, sessions, tasks, journals, cron state
|   |   +-- log.db.lock           OS-level flock sidecar; one Tron process owns it while running
|   |   +-- journals/             Streaming journals for crash recovery of partial LLM output
|   +-- run/                      Mutable runtime state and local contributor artifacts
|   |   +-- auth.lock             Auth-file refresh lock
|   |   +-- .mac-wrapper.lock     Mac wrapper single-instance lock
|   |   +-- .onboarded            First-run sentinel; presence drives `system.getInfo.paired`
|   |   +-- updater-state.json    Update-check scheduler state (lastCheckAt, latestAvailableVersion, latestDownloadUrl)
|   |   +-- Tron-Dev.app          Optional `tron dev` headless agent bundle
|   |   +-- Tron-Deploy.app       Optional contributor shell-service bundle
|   |   +-- tron-cli              Optional contributor CLI shim symlinked from `~/.local/bin/tron`
|   |   +-- tron-lib.sh           Optional contributor CLI helper library
|   |   +-- *.log, *.json, *.bak  Optional contributor run logs, sentinels, and rollback backup
|   +-- transcription/            Speech-to-text sidecar, created by the Mac wizard transcription step or contributor tooling
|       +-- worker.py             parakeet-mlx Python worker copied from the signed app bundle or repo source
|       +-- requirements.txt      Pip deps for the venv, copied with worker.py
|       +-- venv/                 Auto-created when enabled and the sidecar starts
|       +-- models/hf/            HuggingFace model cache (HF_HOME), populated by the first enabled sidecar run
+-- workspace/                    User working area (mounted into agent context)
    +-- vault/                    AES-256-CBC encrypted credential store (entries/, index.json, .master-key)
    +-- knowledge/                Long-term notes and research
    +-- memory/                   User-memory root (auto-injected into every session)
    |   +-- MEMORY.md             Canonical single-file root (name, email, preferences)
    |   +-- rules/                Detail files (listed in context, read on demand)
    |   |   +-- SYSTEM.md         Optional global system-prompt override
    |   |   +-- *.md              User-curated detail files (user-preferences.md, publish-website.md, ...)
    |   +-- sessions/             Auto-generated session retain summaries
    +-- reports/                  Analysis and investigation reports
    +-- automations/              Cron job working directories + automations.json
    +-- scratch/                  Downloads, temp files, experiments
    +-- screenshots/              Saved screenshots from the computer-use tool
    +-- plans/                    Plan files written during plan mode
    +-- renders/                  Generated artifacts (PDFs, images, ...)
    +-- voice notes/              Voice note recordings
```

Notes:
- `~/.tron/user/` is reserved (`paths::user_dir()`) but not currently populated.
- Credentials for external CLIs (Google Workspace, etc.) live in `workspace/vault/`. See the relevant skills for the materialization pattern.
- Additional sentinels at the root of `~/.tron/` toggle worker behavior: `auto-deploy.pause` (contributor-only watcher) and `auto-update.pause` (DMG-user self-updater). Both are managed by the respective `pause`/`resume` CLI subcommands.

### Service (SMAppService)

The production Mac app registers `com.tron.server` with `SMAppService.agent(plistName: "com.tron.server.plist")`. The notarized app must live at `/Applications/Tron.app`; the bundled LaunchAgent lives inside the app at `Contents/Library/LaunchAgents/com.tron.server.plist`, and its `BundleProgram` points at `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` with `ProgramArguments` of `tron --port 9847 --quiet`. `AssociatedBundleIdentifiers` lists the wrapper bundle IDs (`com.tron.mac`, `com.tron.mac.dev`) so Login Items/TCC attribution follows the responsible wrapper app. No production code writes `~/Library/LaunchAgents` or copies an app bundle into `~/.tron/system/`. An enabled Login Item registration without a loaded launchd job is not treated as installed/running; the current app replaces that registration through SMAppService and still waits for the server heartbeat.

Local Release builds use the same path rule: copy the built `Tron.app` to `/Applications/Tron.app` before testing install/registration. If a DMG build is already installed, the local Release build replaces that same slot; stop the wrapper/server before copying, then reopen `/Applications/Tron.app` and restart/resume the helper. Debug Xcode builds use bundle ID `com.tron.mac.dev`, may run from DerivedData for wrapper dogfood, and must be Apple Development signed with a hardened-runtime helper because `SMAppService` can register an ad-hoc bundle but launchd will refuse to spawn it. For agent-only iteration, `tron dev` stops the LaunchAgent, binds port `9847`, and later restores the installed helper through the wrapper's internal `--tron-start-server-and-quit` command so ServiceManagement remains the only registration path.

For local Mac wrapper builds that need real push delivery, copy `packages/mac-app/.env.local.example` to `packages/mac-app/.env.local` and set `TRON_RELAY_URL`, `TRON_RELAY_SECRET`, and optionally `TRON_RELAY_ENVIRONMENT`. `packages/mac-app/scripts/bundle-agent.sh` reads only those relay keys from the ignored file immediately before Cargo compiles the staged helper, so Xcode Debug and local Release tests do not require repeated shell exports. Production DMG builds still get relay values only from GitHub Actions secrets.

### DMG Release Pipeline

End-users install `Tron.app` via a notarized DMG published to GitHub Releases. Release identity is centralized in `VERSION.env`: the first beta is canonical `0.1.0-beta.1`, Apple bundles receive numeric `MARKETING_VERSION = 0.1.0` / `CURRENT_PROJECT_VERSION = 1`, and human-facing UI renders `v0.1 (Beta 1)`. The pipeline lives at `.github/workflows/release-mac.yml` and triggers on a matching `mac-v*` tag push:

1. Checkout + Rust toolchain/cache (`actions-rust-lang/setup-rust-toolchain`).
2. `scripts/tron version check` verifies `VERSION.env`, Cargo, Cargo.lock, Mac/iOS `project.yml`, custom bundle canonical version keys, and release docs agree before any artifact is built. A tag push must equal `mac-v$(TRON_VERSION)`.
3. `cargo build --release --bin tron --locked` in `packages/agent/`, with `TRON_RELAY_URL`, `TRON_RELAY_SECRET`, and `TRON_RELAY_ENVIRONMENT=production` supplied from GitHub secrets so push delivery is enabled for release users without local config.
4. Install XcodeGen + `create-dmg`.
5. `packages/mac-app/scripts/bundle-agent.sh --skip-build` stages `packages/agent/target/release/tron` into `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` and writes the bundled LaunchAgent plist.
6. `xcodegen generate` inside `packages/mac-app/`.
7. Create an isolated release keychain from the signing/notarization secrets, or fall back to dry-run ad-hoc signing when secrets are absent.
8. `xcodebuild archive` with `-scheme TronMac -configuration Release`.
9. Verify the bundled helper, LaunchAgent plist, managed skills, and transcription resources are present in the archive.
10. Sign the helper app first, then sign `Tron.app` with hardened runtime + `TronMac.entitlements`; verify inside-out signatures before DMG packaging.
11. `xcrun notarytool submit` the signed `Tron.app` with `$NOTARIZE_PROFILE` (`tron-notarize`); staple the app on success.
12. Build the DMG with `create-dmg`, sign the DMG, submit that signed DMG to `notarytool`, then staple the DMG. The app and DMG require separate notary tickets.
13. Upload dSYMs to Sentry via `sentry-cli`.
14. `gh release create mac-v0.1.0-beta.1 ./Tron-mac-v0.1.0-beta.1.dmg` creates a draft GitHub pre-release titled `Tron Mac v0.1 (Beta 1)`; maintainers publish after installing and verifying the DMG.

A parallel dry-run job runs on every PR that touches `packages/mac-app/**` or the workflow itself. The dry-run stops before notarization (no cert needed) so PR contributors can verify the assembly pipeline without secrets.

**iOS distribution is separate** — use the `/publish` skill (`/publish bump && /publish build`) which handles archive → IPA → asc upload to App ID `6761511764`. TestFlight indefinitely; no App Store submission planned.

### User-mode Update Checks

For users installed via DMG (no git remote), the server can poll GitHub Releases and surface the notarized DMG URL per the `server.update.*` settings. The module lives at `packages/agent/src/server/updater/mod.rs`. Installing an update remains a visible replacement of `/Applications/Tron.app` from the notarized DMG; the server does not mutate the signed app bundle or stage update artifacts under `~/.tron`. After app replacement, the wrapper syncs bundled managed skills into `~/.tron/skills/` the next time the menu-bar app opens or starts the helper.

| Phase | Action | Effect |
|-------|--------|--------|
| Check | `system.checkForUpdates` | Queries `api.github.com/repos/mhismail3/tron/releases`; returns the highest semver allowed by `channel` (`stable` excludes pre-release tags, `beta` includes them). Cached 60s to avoid rate-limit thrash. |
| Notify | `action: "notify"` | Emits `server.update_available`; iOS banner + menu-bar submenu surface the release and DMG URL. No server-side download. |

Safety invariants (all test-covered):

- No app-bundle mutation: runtime files stay outside `Tron.app`, and replacing the app is a user-visible DMG install.
- Skipped if a dev server has taken over port 9847 (same guard as `auto-deploy`).
- Pause-able via `~/.tron/auto-update.pause` sentinel; `tron self-update pause|resume` manages it.

**Contrast with `tron auto-deploy`**: the latter is contributor-only, pulls from `origin/main`, and refuses to run outside a git repo. Users on DMG-installed builds use `tron self-update` exclusively. See [CLI Reference → Deployment](#cli-reference) for the full command surface.

---

## Testing

### Rust Tests

```bash
cd packages/agent
cargo test                   # Full suite (single `tron` crate)
cargo test paths::           # Filter by module path
cargo test --quiet           # Quiet output
```

The agent is a single `tron` crate, so `cargo test` runs everything (lib unit tests, integration tests, doc tests, the `main_tests.rs` binary tests). Test counts are intentionally not hardcoded in this README — they drift within days and mislead readers. Re-derive from `cargo test --quiet` output when you need the current number.

### iOS Tests

```bash
cd packages/ios-app
xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### CI

```bash
tron ci                      # Run every check (fmt, check, clippy, test, bench, doc)
tron ci fmt check            # Subset: formatting + compilation
tron ci clippy test          # Subset: linting + tests
```

Install the local hook once per clone with `scripts/install-hooks.sh`; it
blocks commits with staged Rust formatting drift and runs the personal-info
guard on staged changes.

Rust clippy CI uses the lint policy in `packages/agent/Cargo.toml`: correctness,
suspicious, performance, and a short list of footgun lints fail the build;
style/pedantic suggestions stay advisory so the signal is not buried.

---

## Core Invariants

These constraints are enforced in code with `// INVARIANT:` markers at the enforcement site.

1. **Canonical internal model**: Handlers and runtime use canonical shapes. iOS wire-format adaptation is boundary-only (`rpc/adapters.rs`).

2. **Fail-fast on unknown models**: Unknown model or provider returns a typed `UnsupportedModel` error immediately. No silent fallback or default provider substitution.

3. **Deterministic event reconstruction**: Session state is always reconstructable from the immutable event log. No mutable session state stored outside events.

4. **Session-serialized writes**: All event appends are serialized per-session via in-process mutex locks. SQLite `UNIQUE(session_id, sequence)` enforces ordering at the DB level.

5. **Event ordering (iOS send button)**: `agent.ready` is emitted AFTER `agent.complete`. iOS `handleComplete()` sets `isPostProcessing=true`, `handleAgentReady()` clears it. Three independent send-button concerns: `isPostProcessing`, `isCompacting`, and ledger (fully async).

6. **Compaction before ledger**: Memory manager runs compaction then ledger sequentially. `compact.boundary` events always precede `memory.ledger` events in the event log.

7. **Hook drain ordering**: Background hooks are drained before accepting a new prompt (pre-run) and before session reconstruction (resume). Prevents stale hook state from interfering.

8. **Production DB guard**: Startup validates the database path is `~/.tron/system/database/log.db` only. Rejects alternate filenames, wrong directories, and symlinked paths.

9. **Single-process DB ownership**: Startup takes an OS-level `flock(2)` on `log.db.lock` before opening the connection pool. A second `tron` process pointed at the same database aborts with a clear error naming the holder's PID, instead of silently racing on `(session_id, sequence)` writes. Released on process exit (normal or abnormal). Enforced by `events/sqlite/process_lock.rs::acquire_database_lock` called from `init_database` in `main.rs`.

---

## License

MIT

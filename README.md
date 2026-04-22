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
+-- packages/
|   +-- agent/              Rust agent server (single `tron` crate, modular layout)
|   +-- ios-app/            SwiftUI iOS application
+-- scripts/
|   +-- tron                CLI for build, deploy, service management
|   +-- tron-lib.sh         Shared bash helpers used by scripts/tron
|   +-- tron-cli            Runtime CLI deployed alongside the server
|   +-- auto-deploy         Background auto-deploy worker
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

---

## Quick Start

### Prerequisites

- **Rust**: `rustup` + `cargo` (stable toolchain)
- **Xcode 16+** (for iOS app)
- **XcodeGen**: `brew install xcodegen`

### First-Time Setup

```bash
./scripts/tron setup       # Check prerequisites, build, create ~/.tron/
./scripts/tron login       # Authenticate with Claude (OAuth browser flow)
```

### Build and Run

```bash
# Build the server
cd packages/agent
cargo build --release

# Development mode (foreground, auto-rebuild)
./scripts/tron dev

# Or install as launchd service
./scripts/tron install
```

### iOS App

```bash
cd packages/ios-app
brew install xcodegen
xcodegen generate
open TronMobile.xcodeproj
```

Build with the `Tron` scheme (or `Tron Beta` for the beta variant). The app connects to `ws://localhost:9847/ws` by default.

---

## CLI Reference

The `scripts/tron` CLI manages the full development and deployment lifecycle. The dispatch table is at the bottom of `scripts/tron` (the `case "$1" in` block); when adding or renaming a subcommand, update this table.

### Development (workspace only)

| Command | Description |
|---------|-------------|
| `tron dev` | Start the dev-profile server in the foreground (`-b` build first, `-t` test first, `-d` background) |
| `tron ci` | CI checks: any subset of `fmt`, `check`, `clippy`, `test`, `bench`, `doc` |
| `tron bench` | Performance benchmarks (`run`, `bless`, `compare`) |
| `tron setup` | First-time project setup |
| `tron ios` | Build/run TronMobile on iOS devices or simulators (`-b` beta, `-d <alias>` device, `-s` simulator, `-g` generic, `-v` verbose). Subcommands: `build`, `run` (default), `stop`, `clean`, `test`, `logs`, `gen`, `devices`. Device UDIDs live under the `ios` key in `~/.tron/system/settings.json`; register them with `tron ios devices add`. macOS-only; loaded from `scripts/tron-ios.sh`. |

### Deployment (workspace only)

| Command | Description |
|---------|-------------|
| `tron preflight` | Pre-deploy infrastructure check |
| `tron deploy` | Build, test, swap binary, restart, health-check (`--force` skips confirms; `--ci` is non-interactive) |
| `tron install` | Initial install (launchd plist + CLI symlink) |
| `tron uninstall` | Remove launchd service (preserves `~/.tron/` data) |
| `tron auto-deploy` | Remote auto-deploy watcher (`install`, `uninstall`, `status`, `pause`, `resume`, `logs`) |

### Runtime

| Command | Description |
|---------|-------------|
| `tron start` | Start the launchd service (`com.tron.server`) |
| `tron stop` | Stop the service |
| `tron restart` | Restart the service |
| `tron status` | Show service status, PID, port |
| `tron rollback` | Restore the previous binary from backup (`--yes` skips confirm) |
| `tron login` | Authenticate with a provider (`--label <name>` for multi-account) |
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

### Always-on (15)

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
| `NotifyApp` | Send a push notification to iOS. Uses APNS direct, the relay, or a stub fallback depending on `push_service`. |
| `WebFetch` | Fetch and extract content from a URL. Uses an LLM subagent summarizer for large pages. |
| `Display` | Render rich content (images, streams) for iOS clients via blob storage and `DisplayFrame` events. |
| `ComputerUse` | Screenshot, click, type, keypress, scroll, window management. |
| `SpawnSubagent` | Spawn a child agent. Max depth controlled by `agent.subagent_max_depth` (default 3). |
| `ManageJob` | Inspect, signal, and clean up background jobs (Bash backgrounded processes + subagents). |
| `Wait` | Block until specified background jobs complete or hit a timeout. |

### Conditional

| Tool | Registered when | Description |
|------|-----------------|-------------|
| `WebSearch` | A Brave API key is set in `~/.tron/system/auth.json` under the `services.brave` entry | Web search via the Brave Search API. |
| `McpSearch` | At least one MCP server is configured | Meta-tool that searches across all MCP server tool catalogs by keyword. |
| `McpCall` | At least one MCP server is configured | Meta-tool that invokes a specific tool on an MCP server. |

Source-control operations (sync main, push, switch branches, finalize a session into main, resolve merge conflicts) are driven by the user via the iOS Source Control sheet — the agent does not have typed git tools. When a session has a worktree, the agent is told (via a system-prompt block in `runtime/context/system_prompts::GIT_WORKFLOW_PROMPT`) that it can inspect state and make commits via `Bash git …` but must defer destructive / publishing operations to the user.

---

## RPC API

JSON-RPC 2.0 over WebSocket. The full registration list is in `packages/agent/src/server/rpc/handlers/mod.rs` (`register_core`, `register_capabilities`, `register_platform`) — that file is the source of truth. The current registration totals **162 methods** across three groups.

### Connection

```
WebSocket: ws://<host>:<port>/ws    Default port: 9847 (set via --port CLI flag)
Health:    GET  http://<host>:<port>/health
Metrics:   GET  http://<host>:<port>/metrics
```

All messages use JSON-RPC 2.0 framing:

```json
{"jsonrpc":"2.0","method":"system.ping","id":1}
{"jsonrpc":"2.0","result":{"pong":true,"timestamp":"…","serverVersion":"0.1.0","serverProtocolVersion":1,"minClientProtocolVersion":1,"compatible":true},"id":1}
```

`system.ping` accepts optional `{"protocolVersion": <u32>, "clientVersion": <str>}` params. Clients that advertise a `protocolVersion` below `minClientProtocolVersion` receive a `CLIENT_VERSION_UNSUPPORTED` error with details naming both versions; clients that omit the field are accepted as pre-handshake (legacy).

### Core (60)

| Group | Count | Methods |
|-------|------:|---------|
| `system` | 4 | `system.ping`, `system.getInfo`, `system.getDiagnostics`, `system.shutdown` |
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
| `logs` | 1 | `logs.ingest` |
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

The event store uses an immutable, append-only log with **79 typed event variants**. Sessions are tree-structured, supporting fork and rewind. State is always reconstructed from events; no mutable session state is stored outside the log.

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

Settings are server-authoritative. The iOS app reads/writes via `settings.get` / `settings.update` / `settings.resetToDefaults` RPC methods. When settings are updated, the server atomically swaps its cached `Arc<TronSettings>`.

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
    "transcription": { "enabled": true },
    "connectionPresets": []         // iOS quick-connect host/port presets
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
| Ollama    | `llm/ollama/`    | None (local)              | Requires Ollama running locally. See `docs/local-llm-setup.md` |

### Multi-Account

```bash
tron login --label work
tron login --label personal
```

`auth.json` stores accounts under `providers.<name>.accounts[]` (named OAuth entries) and `providers.<name>.apiKeys[]` (named API keys). The active credential per provider is selected by `providers.<name>.activeCredential`, which is `{type: "oauth"|"apiKey", label}`. Manage from the iOS app or via `auth.*` RPC methods.

### Auth Precedence

1. The provider's `activeCredential` from `auth.json` (OAuth or API key, by label)
2. The provider's first non-active OAuth account
3. The provider's first non-active API key
4. Environment variable fallback (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`)

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
- `~/.tron/skills/`, `~/.claude/skills/` — Global (all projects). First-party skills under `packages/agent/skills/` are synced into `~/.tron/skills/` by `tron dev` / `tron install` and carry a `.managed` sentinel file. `~/.claude/skills/` is read-only to Tron (Claude Code owns that tree) but its contents are detected automatically.
- `.tron/skills/` or `.claude/skills/` under the working directory (any depth) — Project-local (higher precedence than globals). `.tron/skills/` wins over `.claude/skills/` on same-name collision within a single scope.

**Usage:** Reference with `@skill-name` in prompts. The injector extracts references, resolves them from the registry, and prepends the skill content as `<skills>` XML context. Session-scoped activation is also exposed via `skill.activate` / `skill.deactivate` RPC methods.

### Hooks

Async lifecycle hooks execute before/after tool calls and around prompts:

- **Discovery:** `.agent/hooks/` (project), `~/.config/tron/hooks/` (global)
- **Extensions:** configurable via `hooks.extensions` (default `.ts`, `.js`, `.mjs`, `.sh`)
- **Background hooks:** drained before accepting a new prompt and before session reconstruction (see Core Invariant #7)

---

## Database Schema

All data lives in a single SQLite file: `~/.tron/system/database/log.db`. WAL mode with 5 s busy timeout for concurrent access. Migrations live under `packages/agent/src/events/sqlite/migrations/` (`v001_schema.sql` — the core event store; `v002_schema.sql` — the prompt library tables; `v003_remove_spells.sql` — strips legacy spell events; `v004_session_use_worktree.sql` — adds `sessions.use_worktree` for the per-session worktree override; `v005_sessions_use_worktree_check.sql` — enforces `use_worktree IN (0, 1, NULL)` via triggers; `v006_device_token_bundle_id.sql` — adds `device_tokens.bundle_id` so the relay can route each token to the correct APNs topic per build; `v007_device_tokens_workspace_scope.sql` — widens the `device_tokens` identity from `(device_token, platform)` to `(device_token, platform, workspace_id, bundle_id)` via a rebuilt table + `COALESCE`-nullable unique index, so the same APNs push token can register across multiple workspaces or bundles without clobbering) and are registered in `migrations/mod.rs`, which is the source of truth for schema versioning.

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
| `device_tokens` | iOS push notification tokens — identity is `(device_token, platform, workspace_id, bundle_id)` (v007 rebuild; `bundle_id` column added in v006 so the relay can send Beta-scheme tokens to the correct APNs topic; COALESCE-nullable unique index collapses NULL workspace/bundle to a single canonical row) |
| `notification_read_state` | Per-event read receipts for client notifications |
| `cron_jobs` | Cron job definitions: schedule, payload, delivery, overlap/misfire policies, runtime state (next/last run, consecutive failures) |
| `cron_runs` | Per-run history for cron jobs (status, started/completed timestamps, output, exit code) |
| `prompt_history` | Deduplicated interactive-prompt history keyed by normalized text hash (use_count, first/last_used_at, char_count). Added in v002 migration. |
| `prompt_snippets` | User-authored reusable prompt snippets (`name`, `text`, timestamps). Added in v002 migration. |

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
+-- Services/             Network (RPC client, WebSocket, deep links), audio, push notifications
+-- ViewModels/           Chat view models, handlers, managers, @Observable state
+-- Views/                SwiftUI views (chat, tools, voice notes, settings, ...)
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

### Data Flow

```
Live:    WebSocket -> RPCClient -> EventRegistry -> Plugin -> EventDispatchCoordinator -> ChatViewModel
Stored:  EventDatabase -> UnifiedEventTransformer -> [ChatMessage] -> ChatViewModel -> ChatView
```

### Build Configurations

| Config | Use |
|--------|-----|
| Beta | Debug build, beta server endpoint, side-by-side bundle ID |
| Prod | Release build, production server endpoint |

### Documentation

Detailed iOS documentation lives in `packages/ios-app/docs/`:

- `architecture.md` — App architecture, patterns, file placement
- `development.md` — Xcode setup, builds, testing
- `events.md` — Event plugin system
- `apns.md` — Push notification setup

---

## Deployment

### Deploy Pipeline

```bash
tron deploy          # Full pipeline with confirmations
tron deploy --force  # Skip uncommitted-changes / test-failure prompts
tron deploy --ci     # Non-interactive: any failure aborts
```

The deploy process (`scripts/tron::cmd_deploy`):

1. Aborts if a dev server is bound to the prod port.
2. Warns on uncommitted changes (errors out under `--ci`).
3. Builds the release binary (`cargo build --release`).
4. Runs `cargo test`. Failures prompt for continuation unless `--ci`.
5. Under `--ci`, also runs the benchmark gate.
6. Acquires a deploy lock at `~/.tron/system/deployment/deploy.lock`.
7. Backs up the current binary to `~/.tron/system/deployment/tron.bak`.
8. Stops the launchd service.
9. Re-creates the macOS app bundle at `~/.tron/system/Tron.app` with the new binary, codesigns it with the best-available identity (Developer ID Application > Apple Development > ad-hoc), and — when signed with Developer ID and `tron-notarize` credentials exist in Keychain — submits it to Apple's notary service and staples the ticket. Notarization is non-fatal; deploy succeeds even if Apple rejects, the network fails, or credentials are missing. One-time setup: `xcrun notarytool store-credentials "tron-notarize" --apple-id <email> --team-id <TEAM_ID>`.
10. Deploys the transcription sidecar via `deploy_transcription_sidecar` and syncs managed skills.
11. Reloads the launchd plist and runs health checks.
12. Auto-rollback restores `tron.bak` on failure.

### Install Directory

All paths in the tree below are resolved through helpers in `packages/agent/src/core/foundation/paths.rs`. To rename a directory, change the constant in `dirs::*` there and every call site updates automatically.

```
~/.tron/
+-- skills/                       Global skills (SKILL.md files); managed entries have a .managed sentinel
+-- system/
|   +-- Tron.app/                 macOS app bundle (Contents/MacOS/tron is the server binary)
|   +-- settings.json             User settings (deep-merged over defaults)
|   +-- auth.json                 LLM provider OAuth tokens + API keys (mode 600)
|   +-- defaults/                 Seed copies of settings.json and auth.json (used on first install)
|   +-- database/                 SQLite event store
|   |   +-- log.db                Events, sessions, tasks, journals, cron state
|   |   +-- log.db.lock           OS-level flock sidecar; one Tron process owns it while running
|   |   +-- journals/             Streaming journals for crash recovery of partial LLM output
|   +-- deployment/               Deploy state: tron-cli, tron-lib.sh, deployed-commit, ...; optional apns.json + AuthKey_*.p8 for direct APNs
|   +-- transcription/            Speech-to-text sidecar
|       +-- worker.py             parakeet-mlx Python worker (stdin/stdout JSON-line protocol)
|       +-- requirements.txt      Pip deps for the venv
|       +-- venv/                 Auto-created on first transcription request
|       +-- models/hf/            HuggingFace model cache (HF_HOME)
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

### Service (launchd)

Managed by the `com.tron.server` launchd plist. The entry point is the Rust binary inside the macOS app bundle: `~/.tron/system/Tron.app/Contents/MacOS/tron --port 9847 --quiet`. The plist is generated by `scripts/tron install` and lives at `~/Library/LaunchAgents/com.tron.server.plist`.

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

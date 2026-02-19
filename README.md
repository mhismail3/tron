# Tron

**A persistent, event-sourced AI coding agent for macOS.**

Tron is a local-first AI coding agent that runs as a persistent background service. A Rust server handles LLM communication, tool execution, and event-sourced session persistence. A native iOS app provides a real-time chat interface with streaming, session management, and push notifications.

This README is the single, canonical reference for the project. The Rust codebase is self-documenting: `lib.rs` files describe each crate's purpose and dependencies, `mod.rs` files map submodules, and `// INVARIANT:` comments mark critical correctness constraints. iOS documentation lives in `packages/ios-app/docs/`.

---

## Table of Contents

- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Rust Crates](#rust-crates)
- [Quick Start](#quick-start)
- [CLI Reference](#cli-reference)
- [Tools](#tools)
- [RPC API](#rpc-api)
- [Event System](#event-system)
- [Settings](#settings)
- [Authentication](#authentication)
- [Context and Compaction](#context-and-compaction)
- [Semantic Memory](#semantic-memory)
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
|  |  MiniMax    |  | subagents |  |  memory    |  |  Subagent coordination | |
|  +-------------+  +-----------+  +------------+  +------------------------+ |
+------------------------------------+----------------------------------------+
                                     |
                                     v
+-----------------------------------------------------------------------------+
|                         Event Store (SQLite)                                |
|   - Immutable event log with tree structure (fork/rewind)                   |
|   - Session state reconstruction via ancestor traversal                     |
|   - Full-text search (FTS5), task management (PARA), vector embeddings      |
+-----------------------------------------------------------------------------+
```

### Data Path

1. Client sends JSON-RPC 2.0 over WebSocket
2. `tron-server` dispatches to the appropriate RPC handler
3. Handlers call into runtime, orchestrator, and event store
4. Domain output is adapted at the boundary (`rpc/adapters.rs`) when iOS compatibility is required
5. Events and responses broadcast back through WebSocket channels

---

## Repository Structure

```
tron/
+-- packages/
|   +-- agent/              Rust agent server (Cargo workspace, 12 crates)
|   +-- ios-app/            SwiftUI iOS application
+-- scripts/
|   +-- tron                CLI for build, deploy, service management
|   +-- artifacts/          Benchmark outputs (gitignored)
+-- .claude/
    +-- CLAUDE.md           AI agent project instructions
    +-- rules/              Path-scoped AI navigation rules
```

---

## Rust Crates

The server is a Cargo workspace of 12 crates. Dependencies flow top-down; no cycles.

```
tron-core             Foundation types, errors, branded IDs, message model
  |
  +-- tron-settings         Settings schema, layered loading, global singleton
  +-- tron-llm              Provider trait, model registry, SSE streaming, auth
  |     +-- anthropic/        Claude (OAuth + API key, cache pruning)
  |     +-- openai/           GPT/o-series (OAuth + API key)
  |     +-- google/           Gemini (Cloud Code Assist + Antigravity OAuth)
  |     +-- minimax/          MiniMax (API key only)
  +-- tron-events           SQLite event store, migrations, reconstruction
  +-- tron-tools            Tool trait, registry, 18 tool implementations
  +-- tron-skills           SKILL.md parser, registry, context injection
  +-- tron-embeddings       ONNX embeddings (Qwen3-0.6B-q4), vector search
  +-- tron-transcription    Native transcription (parakeet-tdt-0.6b via ONNX)
  |
  +-- tron-runtime          Aggregation: agent loop, context, hooks, orchestrator, tasks
  |
  +-- tron-server           Axum HTTP/WS, 101 RPC handlers, event bridge, APNS
  |
  +-- tron-agent            Binary entry point (main.rs), DB policy, CLI subcommands
```

| Crate | Purpose | Key Types |
|-------|---------|-----------|
| `tron-core` | Shared vocabulary for all crates | `Message`, `TronError`, `StreamEvent`, `TronEvent`, `SessionId` |
| `tron-settings` | Layered config (defaults + file + env) | `TronSettings`, `get_settings()`, `reload_settings_from_path()` |
| `tron-llm` | LLM abstraction + model registry | `Provider` trait, `ProviderFactory`, `ProviderStreamOptions` |
| `tron-events` | Event sourcing + SQLite | `EventStore`, `EventType` (60 variants), `SessionEvent` |
| `tron-tools` | Tool implementations | `TronTool` trait, `ToolRegistry`, per-tool structs |
| `tron-skills` | Skill loading + injection | `SkillRegistry`, `process_prompt_for_skills()` |
| `tron-embeddings` | Semantic vector search | `EmbeddingController`, `VectorRepository`, `OnnxEmbeddingService` |
| `tron-transcription` | Speech-to-text | `TranscriptionEngine` |
| `tron-runtime` | Agent execution + orchestration | `TronAgent`, `Orchestrator`, `SessionManager`, `ContextManager` |
| `tron-server` | HTTP/WS + RPC dispatch | `TronServer`, `MethodRegistry`, `RpcContext`, `EventBridge` |
| `tron-agent` | Binary wiring + startup | `main()`, `DefaultProviderFactory`, `db_path_policy` |

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

Build with the `TronMobile` scheme. The app connects to `ws://localhost:9847/ws` by default.

---

## CLI Reference

The `scripts/tron` CLI manages the full development and deployment lifecycle.

### Development

| Command | Description |
|---------|-------------|
| `tron dev` | Start server in foreground (`-b` build first, `-t` test first, `-d` background) |
| `tron ci` | CI checks: `fmt`, `check`, `clippy`, `test`, `doc`, `coverage` (any subset) |
| `tron bench` | Performance benchmarks (`run`, `compare`) |
| `tron setup` | First-time project setup (prerequisites, build, config) |

### Service Management

| Command | Description |
|---------|-------------|
| `tron start` | Start launchd service (`com.tron.server`) |
| `tron stop` | Stop service |
| `tron restart` | Restart service |
| `tron status` | Show service status, PID, port |

### Deployment

| Command | Description |
|---------|-------------|
| `tron deploy` | Build, test, stop, swap binary, start, health check (`--force` to skip confirms) |
| `tron install` | Initial setup (launchd plist + CLI symlink) |
| `tron rollback` | Restore previous binary from backup (`--yes` to skip confirm) |
| `tron uninstall` | Remove launchd service (preserves `~/.tron/` data) |

### Auth & Data

| Command | Description |
|---------|-------------|
| `tron login` | Authenticate with Claude (`--label <name>` for multi-account) |
| `tron backfill-ledger` | Import LEDGER.jsonl entries as memory events |
| `tron logs` | Query database logs (`-h` for filter options) |
| `tron errors` | Show recent errors |

### Direct Cargo Commands

```bash
cd packages/agent
cargo build --release
cargo test --workspace
cargo clippy --workspace -- -D warnings
```

---

## Tools

The agent has 18 tools registered at startup, with 3 additional subagent tools added when auth is available.

### Filesystem

| Tool | Description |
|------|-------------|
| `Read` | Read file contents with line numbers. Supports offset/limit for large files. |
| `Write` | Write content to a file (creates or overwrites). |
| `Edit` | Search-and-replace within files (exact string matching). |
| `Find` | Find files by glob pattern. |
| `Search` | Full-text content search with regex support. |

### System

| Tool | Description |
|------|-------------|
| `Bash` | Execute shell commands with configurable timeout (default 120s, max 600s). |
| `Remember` | Store structured memories for cross-session recall. Persisted as events, optionally embedded for semantic search. |

### Browser

| Tool | Description |
|------|-------------|
| `BrowseTheWeb` | CDP-based browser automation. Renders pages, captures screenshots, extracts content. Requires Chrome. |
| `OpenURL` | Open a URL. On iOS, triggers Safari via tool event (fire-and-forget). |

### Web

| Tool | Description |
|------|-------------|
| `WebFetch` | Fetch and extract content from a URL. Uses LLM summarization (via subagent) for large pages. |
| `WebSearch` | Search the web via Brave Search API. Requires a Brave API key in `~/.tron/auth.json`. |

### UI

| Tool | Description |
|------|-------------|
| `AskUserQuestion` | Prompt the user for input with structured options. |
| `NotifyApp` | Send a push notification to iOS (requires APNS config). Falls back to stub without APNS. |
| `TaskManager` | Create, update, list tasks. Backed by SQLite PARA schema. |
| `RenderAppUI` | Render custom UI components in the iOS app. |

### Subagent

| Tool | Description |
|------|-------------|
| `SpawnSubagent` | Spawn a child agent for parallel tasks. Max depth: 3. |
| `QueryAgent` | Check a sub-agent's status, progress, or partial results. |
| `WaitForAgents` | Block until specified sub-agents complete. |

### Communication

| Tool | Description |
|------|-------------|
| `send_message` | Send a message to another session or external endpoint. |
| `receive_messages` | Receive pending messages. |

---

## RPC API

The server exposes 101 JSON-RPC 2.0 methods over WebSocket at `ws://localhost:9847/ws`. Health check at `GET /health`. Prometheus metrics at `GET /metrics`.

### Connection

```
WebSocket: ws://localhost:9847/ws
Health:    GET http://localhost:9847/health  ->  {"status":"ok"}
Metrics:   GET http://localhost:9847/metrics
```

All messages use JSON-RPC 2.0 format:

```json
{"jsonrpc":"2.0","method":"system.ping","id":1}
{"jsonrpc":"2.0","result":"pong","id":1}
```

### Core Methods (42)

**System** (3): `system.ping`, `system.getInfo`, `system.shutdown`

**Session** (10): `session.create`, `session.resume`, `session.list`, `session.delete`, `session.fork`, `session.getHead`, `session.getState`, `session.getHistory`, `session.archive`, `session.unarchive`

**Agent** (3): `agent.prompt`, `agent.abort`, `agent.getState`

**Model** (2): `model.list`, `model.switch`

**Context** (8): `context.getSnapshot`, `context.getDetailedSnapshot`, `context.shouldCompact`, `context.previewCompaction`, `context.confirmCompaction`, `context.canAcceptTurn`, `context.clear`, `context.compact`

**Events** (5): `events.getHistory`, `events.getSince`, `events.subscribe`, `events.unsubscribe`, `events.append`

**Settings** (2): `settings.get`, `settings.update`

**Tool** (1): `tool.result`

**Message** (1): `message.delete`

**Memory** (4): `memory.getLedger`, `memory.updateLedger`, `memory.search`, `memory.getHandoffs`

**Logs** (1): `logs.export`

### Capability Methods (30)

**Skills** (4): `skill.list`, `skill.get`, `skill.refresh`, `skill.remove`

**Filesystem** (4): `filesystem.listDir`, `filesystem.getHome`, `filesystem.createDir`, `file.read`

**Search** (2): `search.content`, `search.events`

**Tasks** (7): `tasks.create`, `tasks.get`, `tasks.update`, `tasks.list`, `tasks.delete`, `tasks.search`, `tasks.getActivity`

**Projects** (6): `projects.create`, `projects.list`, `projects.get`, `projects.update`, `projects.delete`, `projects.getDetails`

**Areas** (5): `areas.create`, `areas.list`, `areas.get`, `areas.update`, `areas.delete`

**Tree** (5): `tree.getVisualization`, `tree.getBranches`, `tree.getSubtree`, `tree.getAncestors`, `tree.compareBranches`

### Platform Methods (29)

**Browser** (3): `browser.startStream`, `browser.stopStream`, `browser.getStatus`

**Canvas** (1): `canvas.get`

**Worktree** (4): `worktree.getStatus`, `worktree.commit`, `worktree.merge`, `worktree.list`

**Transcription** (3): `transcribe.audio`, `transcribe.listModels`, `transcribe.downloadModel`

**Device** (2): `device.register`, `device.unregister`

**Plan** (3): `plan.enter`, `plan.exit`, `plan.getState`

**Communication** (4): `communication.send`, `communication.receive`, `communication.subscribe`, `communication.unsubscribe`

**Voice Notes** (3): `voiceNotes.save`, `voiceNotes.list`, `voiceNotes.delete`

**Git** (1): `git.clone`

**Sandbox** (4): `sandbox.listContainers`, `sandbox.startContainer`, `sandbox.stopContainer`, `sandbox.killContainer`

---

## Event System

The event store uses an immutable, append-only log with 60 event types. Sessions are tree-structured, supporting fork and rewind. State is always reconstructed from events (no mutable session state stored).

### Event Categories

| Category | Events |
|----------|--------|
| **Session** | `session.start`, `session.end`, `session.fork` |
| **Message** | `message.user`, `message.assistant`, `message.system`, `message.deleted` |
| **Stream** | `stream.text_delta`, `stream.thinking_delta`, `stream.turn_start`, `stream.turn_end` |
| **Tool** | `tool.call`, `tool.result` |
| **Config** | `config.model_switch`, `config.prompt_update`, `config.reasoning_level` |
| **Compaction** | `compact.boundary`, `compact.summary` |
| **Context** | `context.cleared` |
| **Skills** | `skill.added`, `skill.removed` |
| **Rules** | `rules.loaded`, `rules.indexed`, `rules.activated` |
| **Files** | `file.read`, `file.write`, `file.edit` |
| **Errors** | `error.agent`, `error.tool`, `error.provider` |
| **Subagent** | `subagent.spawned`, `subagent.status_update`, `subagent.completed`, `subagent.failed`, `subagent.results_consumed` |
| **Tasks** | `task.created`, `task.updated`, `task.deleted`, `project.created`, `project.updated`, `project.deleted`, `area.created`, `area.updated`, `area.deleted` |
| **Hooks** | `hook.triggered`, `hook.completed`, `hook.background_started`, `hook.background_completed` |
| **Memory** | `memory.ledger`, `memory.loaded` |
| **Worktree** | `worktree.acquired`, `worktree.commit`, `worktree.released`, `worktree.merged` |
| **Metadata** | `metadata.update`, `metadata.tag` |
| **Notification** | `notification.interrupted`, `notification.subagent_result` |
| **Other** | `todo.write`, `turn.failed` |

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

The `EventBridge` also routes browser CDP frames (screenshots, DOM snapshots) when Chrome streaming is active.

---

## Settings

**Location:** `~/.tron/settings.json`

Settings are loaded from three layers (highest priority last):

1. **Compiled defaults** (`TronSettings::default()`)
2. **User file** (`~/.tron/settings.json`, deep-merged over defaults)
3. **Environment variables** (`TRON_*` overrides)

Settings are server-authoritative. The iOS app reads/writes via `settings.get` / `settings.update` RPC methods. When settings are updated, the server atomically swaps its cached `Arc<TronSettings>`.

### Key Configuration

```jsonc
{
  "version": "0.1.0",
  "name": "tron",

  "server": {
    "ws_port": 8080,              // WebSocket port (CLI uses 9847)
    "health_port": 8081,          // Health check port
    "max_concurrent_sessions": 10,
    "heartbeat_interval_ms": 30000,
    "session_timeout_ms": 1800000, // 30 min
    "default_provider": "anthropic",
    "default_model": "claude-sonnet-4-20250514"
  },

  "agent": {
    "max_turns": 100,
    "inactive_session_timeout_ms": 1800000,
    "subagent_max_depth": 3
  },

  "context": {
    "compactor": {
      "max_tokens": 25000,         // Context budget
      "compaction_threshold": 0.85, // Usage ratio triggering compaction
      "target_tokens": 10000,       // Target after compaction
      "preserve_ratio": 0.20,       // Recent messages to keep
      "buffer_tokens": 4000         // Response buffer
    },
    "memory": {
      "max_entries": 1000,
      "embedding": {
        "enabled": true,
        "dtype": "q4",             // 4-bit quantized ONNX
        "dimensions": 512           // Matryoshka-truncated from 1024
      },
      "autoInject": {
        "enabled": true,
        "count": 5                  // Top-k memories to inject per turn
      }
    }
  },

  "tools": {
    "bash": {
      "default_timeout_ms": 120000  // 2 minutes
    }
  },

  "retry": {
    "max_retries": 1
  },

  "hooks": {
    "default_timeout_ms": 5000,
    "discovery_timeout_ms": 10000,
    "extensions": [".ts", ".js", ".mjs", ".sh"]
  }
}
```

---

## Authentication

**Storage:** `~/.tron/auth.json` (mode 600)

The auth system supports OAuth 2.0 (PKCE), API keys, and multi-account selection. OAuth tokens auto-refresh 5 minutes before expiry.

### Providers

| Provider | Auth Methods | OAuth Flow |
|----------|-------------|------------|
| **Anthropic** | OAuth (primary), API key | PKCE via `claude.ai/oauth/authorize` |
| **OpenAI** | OAuth, API key | Standard via `chatgpt.com/backend-api` |
| **Google** | OAuth, API key | Dual endpoint (Cloud Code Assist / Antigravity) |
| **MiniMax** | API key only | N/A |

### Multi-Account

```bash
# Login with a label
tron login --label work
tron login --label personal

# Auth file stores named accounts
# Settings select the active account
```

### Auth Precedence

1. OAuth tokens (preferred — higher rate limits)
2. API key from auth file
3. Environment variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`)

---

## Context and Compaction

The context system manages the LLM's input window. Each turn assembles: system prompt + rules + skills + memory + conversation history + tool results.

### Compaction Pipeline

When context approaches the token budget (85% of `max_tokens`), compaction triggers:

1. **Summarize**: Subagent condenses older messages into a summary
2. **Boundary**: `compact.boundary` event marks the cutoff point
3. **Trim**: Messages before the boundary are replaced with the summary
4. **Ledger**: `memory.ledger` event records the session's key learnings

Compaction always runs before ledger writing (deterministic DB ordering).

### Context Assembly Order

```
System prompt  (stable)
  + Rules        (.claude/rules/ path-matched)
  + Skills       (@skill references from prompt)
  + Memory       (semantic search top-k + workspace lessons)
  + History      (messages since last compaction boundary)
  + Pending      (current user prompt + tool results)
```

### Skills

Reusable context packages stored as `SKILL.md` files with optional YAML frontmatter.

**Locations:**
- `~/.tron/skills/` — Global (all projects)
- `.claude/skills/` or `.tron/skills/` — Project-local (higher precedence)

**Usage:** Reference with `@skill-name` in prompts. The injector extracts references, resolves them from the registry, and prepends the skill content as `<skills>` XML context.

### Hooks

Async lifecycle hooks execute before/after tool calls:

- **Discovery:** `.agent/hooks/` (project), `~/.config/tron/hooks/` (global)
- **Extensions:** `.ts`, `.js`, `.mjs`, `.sh`
- **Background hooks:** Drained before new prompts and before session reconstruction

---

## Semantic Memory

The memory system uses ONNX-based embeddings for cross-session knowledge retrieval.

| Component | Detail |
|-----------|--------|
| **Model** | Qwen3-Embedding-0.6B-ONNX |
| **Quantization** | q4 (4-bit weights, fp32 activations) |
| **Dimensions** | 1024 full output, truncated to 512 via Matryoshka |
| **Pooling** | Last-token |
| **Normalization** | L2 re-normalization after truncation |
| **Storage** | SQLite BLOB columns (no sqlite-vec virtual tables) |
| **Search** | Brute-force KNN with cosine similarity |
| **Model cache** | `~/.tron/mods/models/` |

### Memory Sources

- **Ledger entries**: Session summaries written after compaction
- **Remember tool**: Explicit memory storage by the agent
- **Backfill**: `tron backfill-ledger` imports external LEDGER.jsonl entries

### Auto-Injection

When enabled, the top-k most relevant memories (default 5) are injected into the context at each turn. Workspace-scoped memories get priority; cross-project memories fill remaining budget.

---

## Database Schema

All data lives in a single SQLite file: `~/.tron/database/tron.db`. WAL mode with 5s busy timeout for concurrent access.

### Core Tables

| Table | Purpose |
|-------|---------|
| `schema_version` | Migration version tracking |
| `workspaces` | Project/directory contexts (path, name, timestamps) |
| `sessions` | Session metadata (head pointer, title, model, token counts, tags) |
| `events` | Immutable event log (type, payload, denormalized fields for indexing) |
| `blobs` | Content-addressable storage (hash, compressed content, MIME type) |
| `branches` | Named positions in the event tree |
| `logs` | Application logs (level, component, message, error fields) |
| `device_tokens` | iOS push notification tokens |

### Task Management (PARA)

| Table | Purpose |
|-------|---------|
| `areas` | Ongoing responsibilities |
| `projects` | Time-bound initiatives (belongs to area) |
| `tasks` | Actionable items (belongs to project, supports hierarchy) |
| `task_dependencies` | Blocking relationships between tasks |
| `task_activity` | Audit trail (action, old/new value, timestamp) |
| `task_backlog` | Incomplete tasks persisted across sessions |

### Full-Text Search

FTS5 virtual tables with auto-sync triggers: `events_fts`, `logs_fts`, `tasks_fts`, `areas_fts`.

### Indexes

~35 indexes optimizing common query patterns: session+sequence ordering, timestamp ranges, workspace lookups, event type filtering, tool call ID lookups, and more.

---

## iOS App

**Minimum iOS:** 18.0 | **Swift:** 6.0 | **Build system:** XcodeGen

### Architecture

The app uses MVVM with coordinators, event plugins, and SwiftUI's `@Observable` macro.

```
Sources/
+-- App/                  App entry point, delegates, configuration
+-- Core/
|   +-- DI/               Dependency injection container
|   +-- Events/
|       +-- Plugins/      Live event parsing (WebSocket -> UI-ready result)
|       +-- Transformer/  History reconstruction (stored events -> ChatMessage)
|       +-- Payloads/     Shared Decodable structs
+-- Database/             SQLite event database, queries
+-- Models/               Data models, event types, RPC codables
+-- Services/
|   +-- Network/          RPC client, WebSocket, deep links
|   +-- Events/           Event store, sync
|   +-- Audio/            Recording, transcription
|   +-- Notifications/    Push notifications (APNS)
+-- ViewModels/
|   +-- Chat/             ChatViewModel + extensions (connection, events, messaging)
|   +-- Handlers/         Event handling coordinators
|   +-- Managers/         Specialized state managers
|   +-- State/            @Observable state objects
+-- Views/
    +-- Chat/             Core chat interface
    +-- Tools/            Tool chips + detail sheets
    +-- Components/       Reusable UI components
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
| Debug-Beta / Release-Beta | Beta server endpoint |
| Debug-Prod / Release-Prod | Production server endpoint |

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
tron deploy --force  # Skip confirmations
```

The deploy process:

1. Builds release binary (`cargo build --release`)
2. Runs full test suite (`cargo test --workspace`)
3. Backs up current install (`~/.tron/app/` -> backup)
4. Stops launchd service
5. Copies new build to `~/.tron/app/`
6. Starts service
7. Health checks (5 attempts, 3s apart)
8. Auto-rollback on failure

### Install Directory

```
~/.tron/
+-- app/                  Server binary + production dependencies
+-- database/
|   +-- tron.db           Single SQLite file (events, tasks, logs, vectors)
+-- settings.json         User settings (deep-merged over defaults)
+-- auth.json             OAuth tokens + API keys (mode 600)
+-- skills/               Global skills (SKILL.md files)
+-- mods/
|   +-- apns/             APNS credentials (p8 key + config)
|   +-- models/           Cached ONNX models (embeddings, transcription)
+-- notes/                Agent notes
+-- artifacts/
    +-- canvases/          Generated artifacts
```

### Service (launchd)

Managed by `com.tron.server` launchd plist. Entry point: `bun ~/.tron/app/interface/server.js` (TypeScript legacy) or the Rust binary directly depending on deployment mode.

---

## Testing

### Rust Tests

```bash
cd packages/agent
cargo test --workspace     # ~4,258 tests across 12 crates
cargo test -p tron-server  # Single crate
```

Test breakdown by crate:

| Crate | Tests |
|-------|-------|
| `tron-runtime` | ~1,044 |
| `tron-server` | ~720 |
| `tron-tools` | ~721 |
| `tron-events` | ~446 |
| `tron-llm` | ~325 |
| `tron-core` | ~111 |
| `tron-skills` | ~92 |
| `tron-agent` | ~480 |
| `tron-settings` | ~82 |
| Others | ~237 |

### iOS Tests

```bash
cd packages/ios-app
xcodegen generate
xcodebuild test -scheme TronMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

~92 test files with ~1,196 test cases.

### CI

```bash
tron ci                      # All checks
tron ci fmt check            # Subset: formatting + compilation
tron ci clippy test          # Subset: linting + tests
tron ci coverage             # Test coverage report
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

8. **Production DB guard**: Startup validates the database path is `~/.tron/database/tron.db` only. Rejects alternate filenames, wrong directories, and symlinked paths.

---

## License

MIT

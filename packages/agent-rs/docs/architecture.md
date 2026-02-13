# Tron Agent (Rust) - Architecture

## Overview

The Rust agent server is a ground-up rewrite of the TypeScript `packages/agent/` codebase. It maintains exact behavioral parity with the TypeScript server — the iOS app, WebSocket protocol, database format, event types, RPC methods, and tool behavior are all indistinguishable from the TypeScript implementation.

## Workspace Structure

The agent is organized as a Cargo workspace with 23 crates:

```
packages/agent-rs/
├── Cargo.toml                    # workspace root
├── crates/
│   ├── tron-core/                # foundation types, errors, branded IDs
│   ├── tron-events/              # event sourcing, SQLite, migrations
│   ├── tron-settings/            # configuration (figment), feature flags
│   ├── tron-auth/                # OAuth2, API key, token refresh
│   ├── tron-logging/             # tracing + SQLite transport
│   ├── tron-tokens/              # token counting, cost calculation
│   ├── tron-embeddings/          # ONNX inference, vector search (feature-gated)
│   ├── tron-llm/                 # Provider trait + shared streaming
│   ├── tron-llm-anthropic/       # Anthropic/Claude provider
│   ├── tron-llm-google/          # Google/Gemini provider
│   ├── tron-llm-openai/          # OpenAI provider
│   ├── tron-context/             # context assembly, compaction, rules
│   ├── tron-runtime/             # agent loop, turns, sessions
│   ├── tron-tools/               # Tool trait + all implementations
│   ├── tron-hooks/               # hook engine, registry, background tracker
│   ├── tron-skills/              # skill loader, registry, injector
│   ├── tron-guardrails/          # guardrail engine, rules
│   ├── tron-memory/              # memory manager, ledger writer
│   ├── tron-tasks/               # task/project/area CRUD
│   ├── tron-rpc/                 # JSON-RPC 2.0 protocol, handlers
│   ├── tron-server/              # Axum HTTP + WebSocket server
│   ├── tron-platform/            # browser CDP, APNS, worktrees
│   └── tron-agent/               # binary crate (main entry point)
├── tests/                        # workspace-level integration tests
├── docs/                         # architecture, patterns, migration docs
└── migrations/                   # embedded SQL migration files
```

## Dependency Graph

Crates are layered to avoid circular dependencies:

```
Layer 0 (foundation):   tron-core
Layer 1 (infra):        tron-events, tron-settings, tron-logging, tron-auth, tron-tokens
Layer 2 (LLM):          tron-llm -> tron-llm-{anthropic,google,openai}
Layer 3 (capabilities): tron-context, tron-tools, tron-hooks, tron-skills, tron-guardrails, tron-memory, tron-tasks
Layer 4 (runtime):      tron-runtime
Layer 5 (interface):    tron-rpc, tron-server
Layer 6 (platform):     tron-platform, tron-embeddings
Layer 7 (binary):       tron-agent (wires everything together)
```

Each layer only depends on layers below it. This guarantees:
- No circular dependencies
- Maximum parallel compilation
- Each crate is testable in isolation

## Key Design Decisions

### Traits for Abstraction

Every major subsystem defines a trait that consumers depend on:

- `Provider` (tron-llm): All LLM backends implement this
- `TronTool` (tron-tools): All tools implement this
- `EventStore` (tron-events): Storage backend abstraction

This enables testing with mocks and swapping implementations.

### Newtypes for Type Safety

IDs use branded newtypes to prevent mixing:

```rust
pub struct EventId(String);
pub struct SessionId(String);
pub struct WorkspaceId(String);
```

The compiler prevents passing a `SessionId` where an `EventId` is expected.

### Enums for Exhaustiveness

TypeScript discriminated unions become Rust enums with `#[serde(tag = "type")]`. The compiler enforces exhaustive matching — adding a new event type forces handling everywhere.

### Event Sourcing with SQLite

All state changes are recorded as immutable events in SQLite. The current state is always reconstructible from the event log. The database schema matches the TypeScript version exactly for cross-compatibility.

### Async with Tokio

The server uses Tokio for async I/O. Key patterns:
- `tokio::select!` for abort signal handling in the turn loop
- `tokio::sync::broadcast` for event fan-out to WebSocket clients
- MPSC channels per session for ordered event queuing
- `CancellationToken` for graceful shutdown propagation

## Data Flow

```
iOS App
  │ WebSocket (JSON-RPC)
  ▼
tron-server (Axum)
  │ dispatches to
  ▼
tron-rpc (method registry)
  │ routes to handlers
  ▼
tron-runtime (agent loop)
  │ ┌─ tron-context (assembles prompt)
  │ ├─ tron-llm-* (calls LLM API, streams response)
  │ ├─ tron-tools (executes tool calls)
  │ ├─ tron-hooks (pre/post tool hooks)
  │ └─ tron-events (persists everything)
  ▼
tron-server (broadcasts events back to iOS)
```

## Configuration

Settings use a three-layer merge:
1. Compiled defaults (in `tron-settings`)
2. `~/.tron/settings.json` (user overrides)
3. `TRON_*` environment variables

Settings are server-authoritative — the iOS app reads/writes via RPC.

## File Locations

- Database: `~/.tron/database/`
- Settings: `~/.tron/settings.json`
- Skills: `~/.tron/skills/`
- Auth: `~/.tron/auth.json`
- Logs: `~/.tron/logs/`
- Models cache: `~/.tron/mods/models/`
- APNS: `~/.tron/mods/apns/`

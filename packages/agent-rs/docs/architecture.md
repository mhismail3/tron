# Tron Agent (Rust) Architecture

## Scope

`packages/agent-rs` is the Rust gateway/runtime for Tron agent workflows. The server keeps one canonical internal model and uses a single compatibility boundary for iOS-specific shaping.

## Workspace Crates

```
packages/agent-rs/
├── crates/tron-core           # shared domain types, message/content model, errors
├── crates/tron-events         # sqlite event store, migrations, reconstruction
├── crates/tron-settings       # settings schema + load/merge helpers
├── crates/tron-embeddings     # optional embeddings/indexing
├── crates/tron-llm            # provider abstraction + model registry
├── crates/tron-runtime        # orchestrator, turns, context, pricing
├── crates/tron-tools          # tool definitions + execution backends
├── crates/tron-skills         # skill discovery/registry/injection
├── crates/tron-transcription  # native transcription engine/types
├── crates/tron-server         # RPC handlers + websocket server
├── crates/tron-agent          # production binary wiring all services
└── crates/tron-bench          # benchmark harness and baseline generation
```

## Core Invariants

1. Canonical internal model per concept (`tool_use.arguments`, typed model/provider errors).
2. Compatibility adaptation is boundary-only:
   `crates/tron-server/src/rpc/adapters.rs`.
3. Unknown model/provider paths fail fast with typed errors (no implicit provider/model fallback).
4. Unknown-model pricing is explicit unavailable metadata, not default-tier fallback.
5. Event reconstruction is deterministic from persisted events.
6. Session writes are session-serialized in-process; global lock is limited to non-session/global mutation paths.
7. SQLite uniqueness enforces per-session order via `UNIQUE(session_id, sequence)`.
8. Production DB target is strictly `~/.tron/database/beta-rs.db`.

## Compatibility Boundary

- Canonical handler/runtime output is internal-first.
- iOS wire compatibility is injected in adapter dispatch:
  - RPC result adaptation: `adapt_rpc_result_for_ios(...)`
  - tool execution output adaptation: `adapt_tool_execution_result_for_ios(...)`
- WebSocket dispatch points apply adaptation centrally:
  - `crates/tron-server/src/websocket/handler.rs`
  - `crates/tron-server/src/websocket/event_bridge.rs`

## Data Path

1. Client sends JSON-RPC over WebSocket.
2. `tron-server` dispatches to RPC handlers.
3. Handlers call runtime/orchestrator/event store.
4. Domain output is adapted at boundary (`adapters.rs`) when iOS compatibility is required.
5. Events and responses are emitted back through websocket channels.

## Storage & Startup Safety

- Production startup path guard in `crates/tron-agent/src/db_path_policy.rs`:
  - only `beta-rs.db`
  - only under `~/.tron/database`
  - rejects symlinked DB path targets
- Binary startup (`crates/tron-agent/src/main.rs`) resolves and validates DB path before opening SQLite.


# Rust Server Patterns

## Architectural Patterns

### 1) Canonical-Internal, Adapted-Edge

- Core/runtime/storage keep canonical shapes only.
- iOS/back-compat shaping is boundary-only in:
  `crates/tron-server/src/rpc/adapters.rs`.
- Example: internal `tool_use.arguments` remains canonical; adapter emits `input` only for wire compatibility.

### 2) Fail-Fast Policy

- Unknown model/provider should return typed errors immediately.
- No silent fallback provider/model substitution.
- Pricing unknowns return explicit unavailable metadata, not default cost tier.

### 3) Deterministic Event Sourcing

- Session state must reconstruct from immutable events only.
- Per-session ordering is protected by:
  - in-process session write locks
  - sqlite uniqueness (`UNIQUE(session_id, sequence)`).

### 4) Minimal Global Locking

- Session mutation paths serialize by session ID.
- Global lock is reserved for non-session/global mutation paths only.
- SQLite busy conditions are retried with bounded backoff.

## RPC Handler Patterns

### 1) Keep Async Reactor Clean

- Blocking filesystem work should run in `tokio::task::spawn_blocking`.
- This is now applied in settings and skill refresh handlers and in session-create optimistic preload work.

### 2) Handler Responsibility

- Validate params.
- Call domain services/runtime.
- Return canonical payload.
- Never duplicate adapter logic in handler code.

## Database Safety Pattern

- Production startup must resolve DB path through policy module:
  `crates/tron-agent/src/db_path_policy.rs`.
- Any non-`tron.db` or path outside `~/.tron/database` is rejected before opening SQLite.

## Testing Pattern

1. Red: add/adjust a focused test.
2. Green: implement smallest change to pass.
3. Refactor: simplify while keeping tests green.

Required suites during refactor:

- `cargo test -p tron-server --tests`
- `cargo test -p tron-runtime -p tron-events -p tron-llm`
- `cargo test -p tron-agent --tests`

Benchmark workflow:

- Baseline generation via `scripts/bench/run.sh`
- Output JSON stored under `scripts/bench/baselines/`


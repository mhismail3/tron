# Migration Status (TypeScript -> Rust)

This file tracks the active hardening/refactor pass for `packages/agent`.

Legend:
- `done`: implemented and covered by tests
- `partial`: implemented in major paths; additional cleanup remains
- `pending`: not yet completed

## Current Status

### done

- DB startup guard enforces production DB path:
  `~/.tron/database/tron.db` only.
- Integration tests for DB guard and migration touch behavior:
  `crates/tron-agent/tests/db_path_guard.rs`.
- Unknown model/provider fallback removal (fail-fast typed errors):
  - `crates/tron-agent/src/provider_factory.rs`
  - `crates/tron-llm/src/models/registry.rs`
  - `crates/tron-llm/src/provider.rs`
- Pricing fallback removal; unknown model pricing emitted as explicit unavailable metadata:
  `crates/tron-runtime/src/pipeline/pricing.rs`,
  `crates/tron-runtime/src/agent/turn_runner.rs`.
- Canonical tool-use content model migrated to `arguments` internally:
  - `crates/tron-core/src/content.rs`
  - `crates/tron-runtime/src/pipeline/persistence.rs`
  - iOS `input` compatibility mapped in adapter boundary.
- WebSocket/RPC adapter boundary centralized to `adapters.rs`.
- EventStore contention hardening:
  - session-scoped in-process write locking
  - sqlite busy retry policy for write paths
  - unique index migration for `(session_id, sequence)` (`v003`).
- Hot-path compaction trigger regex precompiled (`LazyLock`).
- Blocking filesystem work moved off async handler paths for settings/skill refresh/session optimistic context preload.
- Benchmark harness and baseline runner added:
  - `crates/tron-bench`
  - `scripts/bench/run.sh`.

### partial

- Handler simplification and cross-handler deduplication are improved, but there is still room to further isolate context/rules/memory loading into dedicated shared services.
- iOS payload surface is centralized at adapter dispatch boundaries, but broader canonicalization of all handler return shapes is still an ongoing cleanup target.

### pending

- Strict benchmark gate enforcement (automated pass/fail in CI against baseline JSON).
- Additional stress/property tests for sustained multi-session write pressure beyond current concurrency suites.


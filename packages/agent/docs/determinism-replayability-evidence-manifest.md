# Determinism Replayability Evidence Manifest

Created: 2026-06-09

Current score: **38/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

Scorecard:
[`determinism-replayability-scorecard.md`](determinism-replayability-scorecard.md)

Inventory:
[`determinism-replayability-inventory.md`](determinism-replayability-inventory.md)
and
[`determinism-replayability-inventory.tsv`](determinism-replayability-inventory.tsv)

## Row Status

| Row | Status | Evidence |
|-----|--------|----------|
| DRC-0 | passed_after_fix | Added scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, and CI/local test target wiring. |
| DRC-1 | passed_after_fix | Source inventory records replay-critical surfaces, storage owner, current order, replay gap, and planned proof owner. |
| DRC-2 | passed_after_fix | Static entropy/order guard scans source for raw time, UUIDv7, RNG, and timestamp-only ordering outside explicit owner paths. |
| DRC-3 | passed_after_fix | Deterministic event/session/workspace/fork identities and invocation-record timestamp constructor are implemented and tested. |
| DRC-4 | pending | Provider request audit event and responder-boundary persistence not yet implemented. |
| DRC-5 | pending | `tron.replay.v1` manifest builder and `session::replay_manifest` operation not yet implemented. |
| DRC-6 | pending | Canonical JSON hashing and stable row-order proof not yet implemented. |
| DRC-7 | pending | Cross-record replay reference proof not yet implemented. |
| DRC-8 | pending | Offline roundtrip harness not yet implemented. |
| DRC-9 | pending | Progressive docs, README, protocol docs, and iOS decode updates will be closed after event/API changes land. |
| DRC-10 | pending | Final closeout awaits all rows and full verification. |

## DRC-0 Evidence

Files added:

- `packages/agent/docs/determinism-replayability-scorecard.md`
- `packages/agent/docs/determinism-replayability-evidence-manifest.md`
- `packages/agent/docs/determinism-replayability-inventory.md`
- `packages/agent/docs/determinism-replayability-inventory.tsv`
- `packages/agent/tests/determinism_replayability_invariants.rs`
- `packages/agent/tests/determinism_replayability/`

Files updated:

- `README.md`
- `scripts/tron.d/quality.sh`
- `.github/workflows/ci.yml`

Focused command:

```bash
cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture
```

Recorded result: pass after tightening the inventory wording for replay order
contracts.

Open rows after DRC-0: DRC-2, DRC-3, DRC-4, DRC-5, DRC-6, DRC-7, DRC-8, DRC-9,
and DRC-10.

## DRC-1 Evidence

Inventory command:

```bash
rg -n "session\\.export|replay|manifest|EventStore|append|sequence|provider_request|ModelResponder|respond|stream|Utc::now|SystemTime::now|Instant::now|Uuid::now_v7|rand::|random\\(|ORDER BY timestamp" /Users/moose/Downloads/projects/tron/packages/agent/src /Users/moose/Downloads/projects/tron/packages/agent/tests /Users/moose/Downloads/projects/tron/README.md
```

Inventory result: replay-critical storage surfaces and entropy/order sources
were recorded in `determinism-replayability-inventory.md` and
`determinism-replayability-inventory.tsv`.

Open rows after DRC-1: DRC-2, DRC-3, DRC-4, DRC-5, DRC-6, DRC-7, DRC-8, DRC-9,
and DRC-10.

## DRC-2 Evidence

Files updated:

- `packages/agent/tests/determinism_replayability/entropy_scanning.rs`

Proof:

- `replay_critical_entropy_is_allow_listed` scans `packages/agent/src/**/*.rs`
  for `Utc::now`, `SystemTime::now`, `Instant::now`, `Uuid::now_v7`, RNG, and
  `ORDER BY timestamp`.
- The test failed before fix on unlisted OAuth flow timing and an agent-runner
  test UUID owner, then passed after those owners were explicitly allowed.

Open rows after DRC-2: DRC-4, DRC-5, DRC-6, DRC-7, DRC-8, DRC-9, and DRC-10.
DRC-5/DRC-6 must keep replay builders out of the entropy allow-list and prove
stable replay ordering.

## DRC-3 Evidence

Files added:

- `packages/agent/src/domains/session/event_store/identity.rs`

Files updated:

- `packages/agent/src/domains/session/event_store/mod.rs`
- `packages/agent/src/domains/session/event_store/factory/mod.rs`
- `packages/agent/src/domains/session/event_store/sqlite/repositories/session/mod.rs`
- `packages/agent/src/domains/session/event_store/sqlite/repositories/workspace.rs`
- `packages/agent/src/domains/session/event_store/store/event_store/event_log.rs`
- `packages/agent/src/domains/session/event_store/store/event_store/session_lifecycle.rs`
- `packages/agent/src/engine/invocation/model.rs`

Proof:

- `append_with_identity` persists explicit event ID/timestamp while preserving
  session sequence/head behavior.
- `create_session_with_identity` and `fork_with_identity` persist explicit
  workspace/session/root event identities and deterministic activity timestamps.
- `InvocationRecord::from_result_at` persists an explicit completion timestamp.

Open rows after DRC-3: DRC-4, DRC-5, DRC-6, DRC-7, DRC-8, DRC-9, and DRC-10.

## Verification Log

| Time | Command | Exit | Notes |
|------|---------|-----:|-------|
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | Initial DRC-0/1 run caught missing exact `cursor ASC` replay-order contract text in the inventory. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-0/1 invariant target passed: 9 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --check` | 1 | Rustfmt found formatter drift in the new invariant test files; fixed with `cargo fmt`. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | Post-format DRC-0/1 invariant target passed: 9 passed, 0 failed. |
| 2026-06-09 | `git diff --check` | 0 | DRC-0/1 checkpoint diff has no whitespace errors. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC-2 guard caught missing allow-list owners for OAuth flow timing and an agent-runner test UUID. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-2/3 invariant target passed: 11 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml with_identity --lib -- --nocapture` | 101 | DRC-3 constructor tests exposed non-deterministic `last_activity_at` updates after root event persistence. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml with_identity --lib -- --nocapture` | 0 | Deterministic identity tests passed: 4 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml invocation_record_from_result_at_pins_timestamp --lib -- --nocapture` | 0 | Invocation-record timestamp seam passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml` | 0 | DRC-2/3 Rust formatting applied cleanly. |
| 2026-06-09 | `git diff --check` | 0 | DRC-2/3 checkpoint diff has no whitespace errors. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml domains::session::event_store:: --lib -- --nocapture` | 0 | Session event-store slice passed after explicit activity timestamp changes: 403 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC invariant target caught stale DRC-0/1 score/status expectations after DRC-2/3 docs were updated. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | Final DRC-2/3 invariant target passed: 11 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --check` | 0 | DRC-2/3 formatted state verified. |
| 2026-06-09 | `git diff --check` | 0 | Final DRC-2/3 checkpoint diff has no whitespace errors. |

## Residual Risk Log

| Risk | Owner Row | State |
|------|-----------|-------|
| Provider audit is not yet durable before stream open. | DRC-4 | Open. |
| Replay manifest does not yet include engine substrate rows. | DRC-5 | Open. |
| Replay hashing/order are not yet byte-stable. | DRC-6 | Open. |
| Offline replay harness does not yet exist. | DRC-8 | Open. |

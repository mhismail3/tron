# Determinism Replayability Evidence Manifest

Created: 2026-06-09

Current score: **50/100**

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
| DRC-4 | passed_after_fix | `model.provider_request` event, responder-boundary audit payload, provider exact-envelope marking, and pre-stream turn-runner persistence are implemented and tested. |
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

## DRC-4 Evidence

Files added:

- `packages/agent/src/shared/protocol/model_audit.rs`
- `packages/agent/src/domains/session/event_store/types/payloads/model.rs`

Files updated:

- `packages/agent/src/shared/protocol/mod.rs`
- `packages/agent/src/domains/model/responder/mod.rs`
- `packages/agent/src/domains/model/providers/shared/provider.rs`
- `packages/agent/src/domains/model/providers/anthropic/provider/mod.rs`
- `packages/agent/src/domains/model/providers/google/provider/mod.rs`
- `packages/agent/src/domains/model/providers/kimi/provider.rs`
- `packages/agent/src/domains/model/providers/minimax/provider.rs`
- `packages/agent/src/domains/model/providers/ollama/provider.rs`
- `packages/agent/src/domains/model/providers/openai/provider/mod.rs`
- `packages/agent/src/domains/agent/loop/turn_runner/mod.rs`
- `packages/agent/src/domains/agent/loop/turn_runner/persistence/mod.rs`
- `packages/agent/src/domains/agent/loop/orchestrator/agent_runner.rs`
- `packages/agent/src/domains/session/event_store/mod.rs`
- `packages/agent/src/domains/session/event_store/types/generated.rs`
- `packages/agent/src/domains/session/event_store/types/payloads/mod.rs`
- `packages/agent/src/domains/session/event_store/types/tests.rs`
- `packages/ios-app/Sources/Engine/Events/Live/EventTypeRegistry.swift`
- `packages/ios-app/Sources/Engine/Persistence/SQLite/EventTypes.swift`
- `packages/ios-app/Sources/Engine/Persistence/SQLite/SessionEvent+Summary.swift`
- `packages/ios-app/Tests/Engine/Events/EventTypeRegistryTests.swift`
- `README.md`

Proof:

- `ModelResponder::request_audit` builds a durable audit payload from the same
  stream options later used by `respond`.
- Provider-backed responders store provider exact-envelope audit bodies when
  providers expose them; the trait default stores a provider-independent
  snapshot for custom responders.
- `execute_turn` persists `model.provider_request` through
  `persist_model_provider_request_audit` before calling `responder.respond`.
- `provider_request_audit_persist_failure_prevents_model_response` aborts the
  persister worker and proves `respond` is not called.
- `provider_request_audit_persists_before_assistant_message` proves the audit
  row is persisted before the assistant message row in session sequence order.

Open rows after DRC-4: DRC-5, DRC-6, DRC-7, DRC-8, DRC-9, and DRC-10.

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
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml provider_backed_request_audit_uses_stream_options_and_exact_payload --lib -- --nocapture` | 101 | DRC-4 compile caught a stale unused `Value` import after changing provider audit return type. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml provider_backed_request_audit_uses_stream_options_and_exact_payload --lib -- --nocapture` | 0 | Model responder audit test passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml provider_request_audit_persist_failure_prevents_model_response --lib -- --nocapture` | 0 | Pre-stream audit persistence failure test passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml typed_payload_model_provider_request --lib -- --nocapture` | 0 | Typed payload test for `model.provider_request` passed: 1 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml provider_request_audit --lib -- --nocapture` | 0 | Agent-runner DRC-4 tests passed: 2 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 101 | DRC-4 invariant run caught test-only `AtomicUsize`/`Ordering` imports at module scope. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | 0 | DRC-4 invariant target passed: 11 passed, 0 failed. |
| 2026-06-09 | `cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml domains::session::event_store::types:: --lib -- --nocapture` | 0 | Event type/payload tests passed after adding `model.provider_request`: 69 passed, 0 failed. |
| 2026-06-09 | `cargo fmt --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --check` | 0 | DRC-4 Rust formatting verified. |
| 2026-06-09 | `xcodegen generate` | 0 | iOS project regenerated after event registry changes. |
| 2026-06-09 | `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests` | 65 | iOS build caught missing `modelProviderRequest` summary switch case. |
| 2026-06-09 | `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests` | 0 | SourceGuard passed after adding non-chat provider request summary: 39 passed, 0 failed. |
| 2026-06-09 | `git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | 0 | `xcodegen generate` left the project file unchanged. |
| 2026-06-09 | `cargo check --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml` | 0 | Agent crate check passed for DRC-4 changes. |
| 2026-06-09 | `git diff --check` | 0 | DRC-4 checkpoint diff has no whitespace errors. |

## Residual Risk Log

| Risk | Owner Row | State |
|------|-----------|-------|
| Replay manifest does not yet include engine substrate rows. | DRC-5 | Open. |
| Replay hashing/order are not yet byte-stable. | DRC-6 | Open. |
| Offline replay harness does not yet exist. | DRC-8 | Open. |

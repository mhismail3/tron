# Failure Semantics Evidence Manifest

Status: **active**

Current score: **62/100**

Branch: `codex/primitive-engine-teardown`

This manifest records row checkpoints, commands, findings, and open loops for
the Failure Semantics Campaign.

## Row Evidence

| Row | Status | Change | Verification | Open loops | Commit |
|---|---|---|---|---|---|
| FSC-0 | passed_after_fix | Added the campaign scorecard, inventory, TSV, evidence manifest, invariant target, and README living-doc links. | `cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture` | FSC-1 through FSC-10 remain open implementation rows. | `e9b180fa1` |
| FSC-1 | in_progress | Updated the source inventory to name canonical envelope owners and changed Rust failure surfaces. | Source scan with `rg` for live `TurnFailed`/`Error`, text-only capability errors, provider/model/runtime mappings, and optional code/category sites. | Close iOS and durable replay rows, then re-audit the TSV against source before closeout. | server core checkpoint |
| FSC-2 | passed_after_fix | Added `shared::server::failure::FailureEnvelope`, canonical category/origin vocabulary, stable failure codes, references, and `details_with_failure`. | `cargo test --manifest-path packages/agent/Cargo.toml shared::server::failure --lib`; `cargo test --manifest-path packages/agent/Cargo.toml shared::protocol::model_capabilities --lib` | None for server-side envelope; consumers remain covered by later rows. | server core checkpoint |
| FSC-3 | in_progress | Added canonical conversions for `CapabilityError`, `EngineError`, `ProviderError`, `ModelResponseError`, and `RuntimeError`. | `cargo test --manifest-path packages/agent/Cargo.toml shared::server::error_mapping --lib`; `cargo test --manifest-path packages/agent/Cargo.toml domains::model --lib`; `cargo test --manifest-path packages/agent/Cargo.toml domains::agent::loop::errors --lib` | Add explicit auth/session/event-store mapping assertions and final enum/source guards. | server core checkpoint |
| FSC-4 | passed_after_fix | Replaced production live `TurnFailed` and `Error` construction with canonical event builders and projected origin/retryable/recoverable/details. | `cargo test --manifest-path packages/agent/Cargo.toml shared::protocol::events --lib` | Durable payload enrichment remains FSC-9. | server core checkpoint |
| FSC-5 | passed_after_fix | Replaced text-only capability failures with canonical `failure_result` details and preserved engine invocation failures in `capability.invocation.completed`. | `cargo test --manifest-path packages/agent/Cargo.toml capability_invocation_executor::tests --lib` | Durable replay/export enrichment remains FSC-9. | server core checkpoint |
| FSC-6 | passed_after_fix | Extended `/engine` WebSocket error frames to serialize canonical failure envelopes with sanitized messages and trace ids. | `cargo test --manifest-path packages/agent/Cargo.toml transport::engine::socket --lib` | Add final static transport guard in FSC-10. | server core checkpoint |
| FSC-7 | passed_after_fix | Preserved provider retryability, recoverability, status, retry-after, provider code, provider/model identity, cancellation, and category through responder/runtime envelopes. | `cargo test --manifest-path packages/agent/Cargo.toml domains::model --lib` | iOS consumption remains FSC-8. | server core checkpoint |
| FSC-8 | pending | Not started. | pending | Update iOS decode/projection parity. | pending |
| FSC-9 | passed_after_fix | Added canonical optional fields to durable error/turn-failed payloads, wrote interrupted durable `turn.failed` rows from `FailureEnvelope`, and exported replay engine invocation errors as `error.failure` plus retained legacy diagnostics. | `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store::types::payloads --lib`; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::replay --lib` | iOS consumption remains FSC-8. | durable replay checkpoint |
| FSC-10 | pending | Not started. | pending | Add final static guards and full verification evidence. | pending |

## FSC-0 Findings

- Active runtime paths directly construct `TronEvent::TurnFailed` in
  `domains/agent/loop/turn_runner/mod.rs`.
- `TronEvent::TurnFailed` and durable `TurnFailedPayload` still allow optional
  code/category.
- The model responder boundary drops provider status, provider code,
  retry-after, provider identity, model identity, and canonical public code.
- Capability invocation engine errors can become plain text `error_result`
  values with no structured failure details.
- `/engine` WebSocket error frames currently preserve code/details/trace id and
  sanitize messages, but lack canonical category, retryability,
  recoverability, and origin.

## Server Core Checkpoint Findings

- Active production live `TurnFailed`/`Error` event construction now flows
  through canonical builders; direct constructors remain only in factories,
  projections, and tests.
- Capability invocation errors now preserve `details.failure` with the full
  canonical envelope, plus model primitive and provider invocation ids.
- Provider errors are classified at the provider boundary and carried through
  `ModelResponseError` and `RuntimeError` instead of being reparsed from strings.
- `/engine` error frames now serialize the canonical envelope under `error`
  while retaining the outer trace id.
- Remaining open loops are auth/session/event-store mapping tests, iOS
  decoding/projection parity, inventory closeout, and final static gates.

## Durable Replay Checkpoint Findings

- Durable `turn.failed` payloads now have optional `retryable`, `origin`, and
  `details` fields; the active interrupted-run writer stores the canonical
  envelope under `details.failure`.
- Durable `error.*` payloads accept canonical fields so future persisted error
  rows do not require a parallel schema.
- Replay engine invocation failures now export `error.failure` with the
  canonical envelope while preserving replay-local diagnostic fields such as
  `kind` and `storedKind`.
- The replay manifest test now covers both successful and failed engine
  invocation rows and verifies byte-stable hashes after the new failure object.

## Verification Log

Focused commands run during the server core checkpoint:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml shared::server::error_mapping --lib
cargo test --manifest-path packages/agent/Cargo.toml shared::server::failure --lib
cargo test --manifest-path packages/agent/Cargo.toml shared::protocol::model_capabilities --lib
cargo test --manifest-path packages/agent/Cargo.toml shared::protocol::events --lib
cargo test --manifest-path packages/agent/Cargo.toml domains::model --lib
cargo test --manifest-path packages/agent/Cargo.toml domains::agent::loop::errors --lib
cargo test --manifest-path packages/agent/Cargo.toml capability_invocation_executor::tests --lib
cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store::types::payloads --lib
cargo test --manifest-path packages/agent/Cargo.toml domains::session::replay --lib
```

## Residual Risk

The server and durable/replay surfaces are materially improved but not a
campaign closeout. iOS parity still decides whether clients rely on the same
envelope everywhere. FSC-10 must add static guards that make direct ad hoc
failure emission regressions fail loudly.

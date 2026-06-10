# Failure Semantics Evidence Manifest

Status: **active**

Current score: **90/100**

Branch: `codex/primitive-engine-teardown`

This manifest records row checkpoints, commands, findings, and open loops for
the Failure Semantics Campaign.

## Row Evidence

| Row | Status | Change | Verification | Open loops | Commit |
|---|---|---|---|---|---|
| FSC-0 | passed_after_fix | Added the campaign scorecard, inventory, TSV, evidence manifest, invariant target, and README living-doc links. | `cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture` | FSC-1 through FSC-10 remain open implementation rows. | `e9b180fa1` |
| FSC-1 | passed_after_fix | Re-audited the inventory and TSV after server, durable replay, iOS, and mapping work. Removed stale gap text, documented provider stream error canonicalization, and aligned replay/capability/turn projection rows with current source. | `rg` stale-marker scan across failure-semantics docs, Rust sources, iOS sources, and iOS event docs; `cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture` | None; final stale-doc/static enforcement moves to FSC-10. | inventory closeout checkpoint |
| FSC-2 | passed_after_fix | Added `shared::server::failure::FailureEnvelope`, canonical category/origin vocabulary, stable failure codes, references, and `details_with_failure`. | `cargo test --manifest-path packages/agent/Cargo.toml shared::server::failure --lib`; `cargo test --manifest-path packages/agent/Cargo.toml shared::protocol::model_capabilities --lib` | None for server-side envelope; consumers remain covered by later rows. | server core checkpoint |
| FSC-3 | passed_after_fix | Added canonical conversions for `CapabilityError`, `EngineError`, `ProviderError`, `ModelResponseError`, `RuntimeError`, auth errors, session not-found codes, and event-store errors. Event-store busy/failure and auth storage/transport/OAuth cases now embed `details.failure` with stable code/category/retryability/origin and safe details. | `cargo test --manifest-path packages/agent/Cargo.toml shared::server::error_mapping --lib -- --nocapture`; `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`; `cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture` | None for current mapped error sources. | error mapping closeout checkpoint |
| FSC-4 | passed_after_fix | Replaced production live `TurnFailed` and `Error` construction with canonical event builders and projected origin/retryable/recoverable/details. | `cargo test --manifest-path packages/agent/Cargo.toml shared::protocol::events --lib` | Durable payload enrichment remains FSC-9. | server core checkpoint |
| FSC-5 | passed_after_fix | Replaced text-only capability failures with canonical `failure_result` details and preserved engine invocation failures in `capability.invocation.completed`. | `cargo test --manifest-path packages/agent/Cargo.toml capability_invocation_executor::tests --lib` | Durable replay/export enrichment remains FSC-9. | server core checkpoint |
| FSC-6 | passed_after_fix | Extended `/engine` WebSocket error frames to serialize canonical failure envelopes with sanitized messages and trace ids. | `cargo test --manifest-path packages/agent/Cargo.toml transport::engine::socket --lib` | Add final static transport guard in FSC-10. | server core checkpoint |
| FSC-7 | passed_after_fix | Preserved provider retryability, recoverability, status, retry-after, provider code, provider/model identity, cancellation, and category through responder/runtime envelopes. | `cargo test --manifest-path packages/agent/Cargo.toml domains::model --lib` | None for current provider consumers. | server core checkpoint |
| FSC-8 | passed_after_fix | Added Swift `CanonicalFailurePayload`; made `/engine` protocol errors decode the full envelope; required child engine errors to carry `details.failure`; changed live `error`/`agent.turn_failed` plugins to require `details.failure` and avoid local placeholder/default classification; made persisted error projections, provider pills, session summaries, and capability error rows prefer the server envelope. | `xcodegen generate`; `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EventPluginTests -only-testing:TronMobileTests/ErrorEventProjectionTests -only-testing:TronMobileTests/EventDispatchCoordinatorTests -only-testing:TronMobileTests/CapabilityInvocationCompletedPluginTests -only-testing:TronMobileTests/EngineProtocolBaseTypesTests`; `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`; `cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture`; `git diff --check` | None for current server-authored iOS failure surfaces. | iOS parity checkpoint |
| FSC-9 | passed_after_fix | Added canonical optional fields to durable error/turn-failed payloads, wrote interrupted durable `turn.failed` rows from `FailureEnvelope`, and exported replay engine invocation errors as `error.failure` plus replay diagnostics. | `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store::types::payloads --lib`; `cargo test --manifest-path packages/agent/Cargo.toml domains::session::replay --lib` | None for current durable/replay surfaces. | durable replay checkpoint |
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
- Remaining open loops are auth/session/event-store mapping tests, inventory
  closeout, and final static gates.

## Error Mapping Closeout Findings

- `map_event_store_error` now emits canonical envelopes for session, event,
  workspace, and blob not-found cases with typed id details.
- Event-store busy maps to retryable `EVENT_STORE_BUSY` with
  `unavailable` category and operation/attempt details; SQLite, pool, serde,
  migration, and internal failures map to `EVENT_STORE_FAILURE` with
  `persistence` category and safe reason/kind details.
- `map_auth_error` now preserves auth-not-configured, token-expired, OAuth,
  auth-storage, and auth-transport failures as canonical envelopes. Malformed
  auth-file errors no longer carry local filesystem paths in public failure
  messages or structured details.
- The static campaign gate now checks the new auth/event-store codes,
  category mapping, mapper branches, and focused test coverage markers.

## Inventory Closeout Findings

- Deleted the unused generic `From<ProviderError> for ModelResponseError`
  conversion that supplied unknown provider/model placeholders.
- Provider `StreamEvent::Error` values are converted at the model responder
  boundary into canonical parse failures with provider/model identity before
  the agent stream processor sees them.
- Replay engine invocation exports now describe their extra data as
  replay-local diagnostic fields.
- Inventory rows now describe current source-backed semantics for the model
  responder, capability completion payload, runtime turn projection, replay
  manifest, auth/event-store mapper, and iOS failure consumers.

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

## iOS Parity Checkpoint Findings

- `CanonicalFailurePayload` is the Swift DTO for the server-authored envelope
  and is decoded from both `/engine` error responses and `details.failure`.
- Live `error` and `agent.turn_failed` plugins no longer synthesize
  `UNKNOWN`, `Unknown error`, turn `0`, or default recoverability when the
  server omits required failure fields.
- Persisted `error.*`, `turn.failed`, provider pill, session summary, and
  expanded-content projections prefer the canonical envelope where present.
- Failed capability completions preserve `details.failure` through live and
  reconstructed UI paths, and capability detail sheets populate code/category
  rows from the envelope.

## Verification Log

Focused commands run during completed checkpoints:

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
cargo test --manifest-path packages/agent/Cargo.toml domains::model::responder --lib
xcodegen generate
xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ErrorEventProjectionTests -only-testing:TronMobileTests/EventPluginTests -only-testing:TronMobileTests/EventDispatchCoordinatorTests
xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineProtocolBaseTypesTests
xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/CapabilityInvocationCompletedPluginTests
```

## Residual Risk

The server, durable/replay, iOS, mapping, and inventory surfaces are materially
improved but not a campaign closeout. FSC-10 must add final static guards that
make stale docs, direct ad hoc failure emission, category drift, uncovered
variants, and stale wording regressions fail loudly.

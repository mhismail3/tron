# Failure Semantics Campaign Scorecard

Status: **active**

Current score: **100/100**

Branch: `codex/primitive-engine-teardown`

This scorecard formalizes the Failure Semantics Campaign. The campaign makes
classified, structured failure semantics a first-class server invariant across
provider/model errors, runtime turn failures, capability invocation results,
engine transport responses, durable events, replay manifests, and iOS
projections.

## Campaign Rules

1. Work row by row and keep this scorecard, the inventory, and the evidence
   manifest current in each checkpoint.
2. Every runtime-visible failure emitted by active code must carry a stable
   non-empty code, stable category, sanitized public message, retryability,
   recoverability, and origin.
3. Public wire fields stay populated. Structured failure data is additive and
   must not create a parallel client taxonomy.
4. No active production path may construct string-only `TurnFailed`, `Error`,
   capability error results, or engine transport errors after closeout.
5. Historical durable rows may remain sparse, but new runtime emissions and new
   replay/audit records must be classified.

## Artifact Map

| Artifact | Status | Purpose |
|---|---|---|
| `packages/agent/docs/failure-semantics-scorecard.md` | active | Weighted campaign rows, open-loop ledger, and current score. |
| `packages/agent/docs/failure-semantics-inventory.md` | active | Human-readable failure surface inventory and mapping notes. |
| `packages/agent/docs/failure-semantics-inventory.tsv` | active | Machine-readable surface inventory used by static gates. |
| `packages/agent/docs/failure-semantics-evidence-manifest.md` | active | Checkpoint evidence, verification commands, and residual risks. |
| `packages/agent/tests/failure_semantics_invariants.rs` | active | Static campaign gates and closeout guards. |

## Scorecard

| Row | Requirement | Points | Status | Owner | Evidence | Closeout note | Checkpoint |
|---|---|---:|---|---|---|---|---|
| FSC-0 | Campaign harness | 6 | passed_after_fix | docs/static gates | Scorecard, inventory, TSV, evidence manifest, invariant target, and README links exist. | Superseded by completed implementation rows and FSC-10 gates. | FSC-0 campaign harness checkpoint |
| FSC-1 | Failure inventory | 8 | passed_after_fix | docs/static gates | Inventory and TSV were re-audited after server, durable replay, iOS, and mapping changes; stale gap rows were removed or replaced with current source-backed semantics. | Enforced by FSC-10 stale-state guards. | inventory closeout checkpoint |
| FSC-2 | Canonical envelope | 12 | passed_after_fix | server error contract | `shared::server::failure::FailureEnvelope` owns code/category/message/retryable/recoverable/origin/provider/model/status/error type/retry-after/suggestion/details/references and `details_with_failure`. | None for current envelope consumers. | server core checkpoint |
| FSC-3 | Error mapping matrix | 12 | passed_after_fix | server/model/engine | `EngineError`, `CapabilityError`, `ProviderError`, `ModelResponseError`, `RuntimeError`, auth, session, and event-store errors now map to canonical failures with focused tests and static source guards. | None for current mapped error sources. | error mapping closeout checkpoint |
| FSC-4 | Runtime event emission | 12 | passed_after_fix | agent runtime | Production live `TurnFailed` and `Error` emissions route through `turn_failed_event` / `error_event`; projections only match events. | Enforced by FSC-10 direct-construction guards. | server core checkpoint |
| FSC-5 | Capability and engine results | 10 | passed_after_fix | engine/capability | Capability executor failures use `failure_result`; engine invocation failures preserve canonical failure details through `capability.invocation.completed`. | Enforced by FSC-10 source guards. | server core checkpoint |
| FSC-6 | Transport contract | 8 | passed_after_fix | transport | `/engine` socket errors serialize the canonical failure envelope with sanitized message, trace id, category, retryability, recoverability, origin, and details. | Enforced by FSC-10 transport-frame guard. | server core checkpoint |
| FSC-7 | Provider retry semantics | 8 | passed_after_fix | model provider boundary | Provider errors now preserve retryability, recoverability, status, retry-after, provider code, cancellation, provider, model, and category through responder/runtime failure envelopes. | None for current provider consumers. | server core checkpoint |
| FSC-8 | iOS parity | 8 | passed_after_fix | iOS client | Swift now decodes `CanonicalFailurePayload`, `/engine` errors require canonical fields, live `error` / `agent.turn_failed` plugins require `details.failure`, persisted projections prefer the envelope, and capability error rows are populated from server failure details. | None for current server-authored failure surfaces. | iOS parity checkpoint |
| FSC-9 | Observability and replay | 6 | passed_after_fix | event store/replay/audit | Durable error payloads accept canonical fields, interrupted durable `turn.failed` writes `details.failure`, and replay engine invocation errors export canonical failure envelopes plus replay diagnostic details. | None for current durable/replay surfaces. | durable replay checkpoint |
| FSC-10 | Closeout gates | 10 | passed_after_fix | static gates/verification | Static guards cover campaign artifact status, direct runtime failure construction, text-only capability result removal, transport canonical fields, iOS canonical decoding, mapped auth/event-store codes, and source-backed inventory rows. | Full verification recorded in the evidence manifest. | closeout gates checkpoint |

## Current Findings

- The server-side canonical envelope and core Rust source mappings are in
  place for live runtime events, model/provider failures, engine transport
  errors, and model-facing capability results.
- `FSC-3` is closed for current mapped error sources: event-store busy and
  persistence failures now preserve retryability, category, origin, and safe
  details; auth storage/transport/OAuth failures preserve sanitized canonical
  details without leaking local paths.
- Durable event payloads and replay exports now preserve canonical failure
  details for the active interrupted turn-failure writer and engine invocation
  replay errors.
- iOS `/engine` decoding, live plugins, persisted projections, provider pills,
  and capability error rows now consume server-provided canonical failure
  envelopes instead of inventing local failure semantics.
- `FSC-1` is closed: the inventory now reflects the deleted model responder
  unknown-provider conversion, provider stream error canonicalization, auth/event-store
  mapping closeout, durable replay diagnostics, and iOS envelope parity.
- `FSC-10` is closed: static gates now reject stale campaign artifact state,
  unauthorized runtime failure constructors, text-only capability error helpers,
  transport frames that skip the canonical envelope, category/code drift, and
  iOS divergence from server-authored failure envelopes.

## Verification Target

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture
```

## Closeout Definition

Closeout is satisfied when this scorecard is `100/100`, every row is marked
`passed_after_fix`, focused Rust and iOS checks pass, full local verification
passes, and the worktree is clean after the final checkpoint commit.

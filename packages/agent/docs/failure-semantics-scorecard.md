# Failure Semantics Campaign Scorecard

Status: **active**

Current score: **62/100**

Branch: `codex/primitive-engine-teardown`

This scorecard formalizes the Failure Semantics Campaign. The campaign makes
classified, structured failure semantics a first-class server invariant across
provider/model errors, runtime turn failures, capability invocation results,
engine transport responses, durable events, replay manifests, and iOS
projections.

## Campaign Rules

1. Work row by row and keep this scorecard, the inventory, and the evidence
   manifest current in the same checkpoint.
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

| Row | Requirement | Points | Status | Owner | Evidence | Open loops | Checkpoint |
|---|---|---:|---|---|---|---|---|
| FSC-0 | Campaign harness | 6 | passed_after_fix | docs/static gates | Scorecard, inventory, TSV, evidence manifest, invariant target, and README links exist. | Implementation rows remain pending. | FSC-0 campaign harness checkpoint |
| FSC-1 | Failure inventory | 8 | in_progress | docs/static gates | Inventory now names the canonical envelope owners and completed Rust source mappings. | Close iOS and durable replay rows, then re-audit the TSV against source before closeout. | server core checkpoint |
| FSC-2 | Canonical envelope | 12 | passed_after_fix | server error contract | `shared::server::failure::FailureEnvelope` owns code/category/message/retryable/recoverable/origin/provider/model/status/error type/retry-after/suggestion/details/references and `details_with_failure`. | None for server-side envelope; iOS/durable consumers remain FSC-8/FSC-9. | server core checkpoint |
| FSC-3 | Error mapping matrix | 12 | in_progress | server/model/engine | `EngineError`, `CapabilityError`, `ProviderError`, `ModelResponseError`, and `RuntimeError` now map to canonical failures with focused tests. | Add explicit auth/session/event-store mapping assertions and final static enum/source coverage. | server core checkpoint |
| FSC-4 | Runtime event emission | 12 | passed_after_fix | agent runtime | Production live `TurnFailed` and `Error` emissions route through `turn_failed_event` / `error_event`; projections only match events. | Durable payload enrichment remains FSC-9. | server core checkpoint |
| FSC-5 | Capability and engine results | 10 | passed_after_fix | engine/capability | Capability executor failures use `failure_result`; engine invocation failures preserve canonical failure details through `capability.invocation.completed`. | Durable capability replay/export enrichment remains FSC-9. | server core checkpoint |
| FSC-6 | Transport contract | 8 | passed_after_fix | transport | `/engine` socket errors serialize the canonical failure envelope with sanitized message, trace id, category, retryability, recoverability, origin, and details. | Add final static guard for transport error frame fields in FSC-10. | server core checkpoint |
| FSC-7 | Provider retry semantics | 8 | passed_after_fix | model provider boundary | Provider errors now preserve retryability, recoverability, status, retry-after, provider code, cancellation, provider, model, and category through responder/runtime failure envelopes. | iOS consumption remains FSC-8. | server core checkpoint |
| FSC-8 | iOS parity | 8 | pending | iOS client | Not started. | Decode canonical fields and remove divergent client classifications where server data exists. | pending |
| FSC-9 | Observability and replay | 6 | passed_after_fix | event store/replay/audit | Durable error payloads accept canonical fields, interrupted durable `turn.failed` writes `details.failure`, and replay engine invocation errors export canonical failure envelopes plus legacy diagnostic details. | None for current durable/replay surfaces; iOS consumption remains FSC-8. | durable replay checkpoint |
| FSC-10 | Closeout gates | 10 | pending | static gates/verification | Not started. | Add guards against stale open loops, ad hoc failure construction, missing codes/categories, category drift, and uncovered variants. | pending |

## Current Findings

- The server-side canonical envelope and core Rust source mappings are in
  place for live runtime events, model/provider failures, engine transport
  errors, and model-facing capability results.
- `FSC-3` remains open because auth/session/event-store mapping assertions and
  final static enum/source guards are not complete.
- Durable event payloads and replay exports now preserve canonical failure
  details for the active interrupted turn-failure writer and engine invocation
  replay errors.
- iOS decoding/projection still needs to consume server-provided canonical
  fields and remove divergent classifications where server data exists.

## Verification Target

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture
```

## Closeout Definition

Closeout requires this scorecard to reach `100/100`, every row to be marked
`passed_after_fix`, all open loops to be closed or moved to a new explicit
successor campaign, focused Rust and iOS checks to pass, full local verification
to pass, and the worktree to be clean after the final checkpoint commit.

# Failure Semantics Campaign Scorecard

Status: **active**

Current score: **6/100**

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
| FSC-1 | Failure inventory | 8 | pending | docs/static gates | Initial source-audited inventory exists. | Verify every active failure surface while implementing later rows and update inventory with final mapping owners. | pending |
| FSC-2 | Canonical envelope | 12 | pending | server error contract | Not started. | Add one canonical server-side failure envelope, vocabulary, builder API, sanitization boundary, and trace/reference support. | pending |
| FSC-3 | Error mapping matrix | 12 | pending | server/model/engine | Not started. | Exhaustively map `EngineError`, `CapabilityError`, `ProviderError`, auth/session/event-store errors, and runtime errors with tests. | pending |
| FSC-4 | Runtime event emission | 12 | pending | agent runtime | Not started. | Replace direct production `TurnFailed` and live `Error` construction with canonical builders. | pending |
| FSC-5 | Capability and engine results | 10 | pending | engine/capability | Not started. | Preserve structured failure details through capability invocation results, engine invocation failures, idempotency, owner mismatch, policy, schema, and replay. | pending |
| FSC-6 | Transport contract | 8 | pending | transport | Not started. | Preserve stable code/category/details and trace IDs in `/engine` error frames with sanitized messages. | pending |
| FSC-7 | Provider retry semantics | 8 | pending | model provider boundary | Not started. | Preserve retryability, recoverability, status, retry-after, provider code, cancellation, provider, model, and category through model responder/runtime. | pending |
| FSC-8 | iOS parity | 8 | pending | iOS client | Not started. | Decode canonical fields and remove divergent client classifications where server data exists. | pending |
| FSC-9 | Observability and replay | 6 | pending | event store/replay/audit | Not started. | Store enough structured failure data for durable events, request audit, engine errors, and replay manifests. | pending |
| FSC-10 | Closeout gates | 10 | pending | static gates/verification | Not started. | Add guards against stale open loops, ad hoc failure construction, missing codes/categories, category drift, and uncovered variants. | pending |

## Current Findings

- `TronEvent::TurnFailed` currently permits missing `code` and `category`, and
  active runtime paths still emit it directly from `turn_runner`.
- Live `TronEvent::Error` has structured fields but still permits missing
  canonical semantics and is constructed directly by runtime/service helpers.
- `ModelResponseError` currently carries message, category, retryable, and
  cancellation only; provider status, provider code, retry-after, provider,
  model, and public code are not preserved at that boundary.
- `ProviderError` has useful native semantics but exposes categories as free
  strings and does not produce the canonical server envelope.
- Capability invocation failures can collapse `EngineError` into model-visible
  text via `error_result` without structured failure details.
- `/engine` WebSocket responses include `code`, sanitized `message`, `details`,
  and `traceId`, but do not yet carry canonical category, retryability,
  recoverability, origin, or safe details consistently.
- Durable error payloads and iOS projections already have partial structured
  support, but they do not yet consume one canonical failure contract.

## Verification Target

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture
```

## Closeout Definition

Closeout requires this scorecard to reach `100/100`, every row to be marked
`passed_after_fix`, all open loops to be closed or moved to a new explicit
successor campaign, focused Rust and iOS checks to pass, full local verification
to pass, and the worktree to be clean after the final checkpoint commit.

# Provider / Model Boundary Discipline Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/provider-model-boundary-discipline-current`
Base commit: `c7deea13d1bcb37b0348406329d503c043933ae6` (`Reconcile off-plan cleanup lineage`)

Stale branch quarantine: `codex/provider-model-boundary-discipline` at
`b11449319` was inspected only as quarry. It was not merged, cherry-picked,
or treated as completion evidence because it diverges from the removed
SAA/generated-worker chain.

Evidence manifest:
[`provider-model-boundary-discipline-evidence-manifest.md`](provider-model-boundary-discipline-evidence-manifest.md)

Inventory:
[`provider-model-boundary-discipline-inventory.md`](provider-model-boundary-discipline-inventory.md)
and
[`provider-model-boundary-discipline-inventory.tsv`](provider-model-boundary-discipline-inventory.tsv)

Invariant target:
[`../tests/provider_model_boundary_discipline_invariants.rs`](../tests/provider_model_boundary_discipline_invariants.rs)

## Scope

This slice hardens the provider/model boundary after PPACD and OPSAA. Model
providers are black boxes behind the provider trait and model responder
boundary. Agent runtime, turn loop, public protocol, replay, and iOS-facing
DTOs consume canonical request-audit, stream, failure, catalog, token, auth, and
retry contracts instead of provider-native wire structs.

The covered providers are OpenAI, Anthropic, Google, Kimi, MiniMax, and Ollama.

## Scenario Ledger

| Row | Name | Weight | Status | Closure requirement |
| --- | --- | ---: | --- | --- |
| PMBD-0 | Baseline, Lineage, and Stale-Branch Quarantine | 5 | passed | Current branch is based on `c7deea13d`; stale PMBD branch at `b11449319` is recorded as quarry only; current source inventory was captured before closure. |
| PMBD-1 | Whole Provider/Model Boundary Inventory | 10 | passed | Structured Markdown and TSV inventory cover provider trait, factory, responder, request builders, stream handlers, capability parsing, id remapping, retry, error parsing, catalog, token/pricing, auth custody, provider audit, redaction, README/protocol docs, and tests. |
| PMBD-2 | Provider Trait and Request Contract Isolation | 10 | passed | Static guards keep provider-native modules out of non-provider/responder source; provider wire request/response types stay under provider modules or protocol helpers. |
| PMBD-3 | Auth Custody and Account-Selection Boundary | 10 | passed | Providers receive ephemeral credential copies through credential-store/factory paths; auth selection stays provider-local; auth failures map to canonical provider/model errors without secret leakage. |
| PMBD-4 | Streaming Normalization and Capability-Call Parsing | 12 | passed | Provider stream handlers normalize to canonical `StreamEvent`s; malformed/non-object capability arguments fail closed; provider invocation IDs remap at provider protocol boundaries; partial/duplicate deltas do not corrupt capability history. |
| PMBD-5 | Error Mapping, Failure Envelopes, and Redaction | 10 | passed | Provider errors map to canonical failure envelopes with stable code/category/origin/retryability/recoverability/provider/model/status/error-type/retry-after/details, and provider-derived messages are redacted. |
| PMBD-6 | Retry, Timeout, Cancellation, and Rate-Limit Semantics | 10 | passed | Retry policy is provider-neutral, bounded, backoff/jitter controlled, honors `Retry-After`, emits retry events, stops on cancellation, and avoids non-retryable auth/parse/model-validation retries. |
| PMBD-7 | Catalog, Model Limits, Reasoning/Capability Flags, and Token Accounting | 8 | passed | Provider detection, prefix stripping, auth-path availability, context limits, reasoning levels, pricing/token normalization, and provider capability flags are explicit registry helpers, not arbitrary model-string inference. |
| PMBD-8 | Provider Request Audit and Replay Boundary | 8 | passed | `model.provider_request` audit payloads are canonical, versioned, redacted and bounded, carry request/audit metadata without secrets, and are the durable replay source for provider request bodies. Exact provider envelopes vs provider-independent snapshots are explicit. |
| PMBD-9 | Docs, README, Predecessor Inventories, and CI Wiring | 9 | passed | PMBD scorecard/evidence/inventory artifacts, README living docs/tests sections, predecessor inventory rows, local `scripts/tron.d/quality.sh`, and GitHub CI static gates are in sync. |
| PMBD-10 | Verification, Adversarial Self-Audit, and Clean Commit | 8 | passed | Focused provider/model/auth/token tests, PMBD invariant, predecessor guards, broad CI, hygiene checks, generated iOS project drift check, and clean worktree are required before commit. |

Total weight: **100**

## Closeout Notes

The source hardening is intentionally narrow:

- Secret redaction is shared from `shared::foundation::redaction` and reused by
  event storage, provider error mapping, retry events, and model responder
  stream-error handling.
- Provider request audit payloads are redacted and size-bounded before the
  responder returns the canonical `ModelProviderRequestAudit` for persistence.
- Static PMBD guards assert provider-native imports and wire markers stay inside
  provider/protocol/routing/token ownership boundaries.

No Performance, Configuration, Release, iOS shell, DX, Documentation/evidence,
or Self-Sufficient Runtime slice work is continued here.

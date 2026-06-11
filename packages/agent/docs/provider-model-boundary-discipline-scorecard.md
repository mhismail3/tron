# Provider / Model Boundary Discipline Scorecard

Status: **closed**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/provider-model-boundary-discipline`
Base commit: `07ba69b4f` (`Harden public protocol contracts`)

Evidence manifest:
[`provider-model-boundary-discipline-evidence-manifest.md`](provider-model-boundary-discipline-evidence-manifest.md)

Inventory:
[`provider-model-boundary-discipline-inventory.md`](provider-model-boundary-discipline-inventory.md)
and
[`provider-model-boundary-discipline-inventory.tsv`](provider-model-boundary-discipline-inventory.tsv)

Invariant target:
[`../tests/provider_model_boundary_discipline_invariants.rs`](../tests/provider_model_boundary_discipline_invariants.rs)

## Scope

This slice hardens the provider/model boundary. Providers remain black-box
request, stream, auth, retry, error, catalog, health, and audit implementations.
Agent runtime, public protocol, generic model responder consumers, and iOS
mirrors consume canonical responder, stream, failure, audit, catalog, and token
contracts rather than provider-native wire shapes.

## Scenario Ledger

| Row | Name | Weight | Status | Closure requirement |
| --- | --- | ---: | --- | --- |
| PMBD-0 | Harness | 5 | passed | Scorecard/evidence/inventory/invariant target exists, is linked from README, is wired into local `scripts/tron ci test` and GitHub `rust-static-gates`, and predecessor inventories cover the new artifacts. |
| PMBD-1 | Provider Boundary Inventory | 10 | passed | Provider modules, shared helpers, responder, factory/auth, model protocol, routing/catalog/token helpers, audit DTO, failure surfaces, and relevant iOS mirrors are inventoried with owner, status, risk, proof target, and action. |
| PMBD-2 | Provider Trait and Responder Boundary | 12 | passed | Non-provider code depends on `ModelResponder` and canonical responder contracts; provider creation, stream opening, retry wrapping, health, audit, and provider-error mapping stay behind responder/factory roots. |
| PMBD-3 | Request and Context Shaping Isolation | 10 | passed | Provider-specific request bodies, headers, beta flags, cache directives, effort mappings, base URLs, and message-conversion formats stay inside provider modules. |
| PMBD-4 | Stream Normalization and Capability Parsing | 12 | passed | Provider stream handlers normalize to canonical `StreamEvent`s, fail closed on malformed capability arguments, preserve deterministic id remapping, and never project provider-native fragments into agent history. |
| PMBD-5 | Error, Retry, Cancellation, and Health Semantics | 10 | passed | Provider errors map into canonical failure/model response errors with provider/model identity, retryability, retry-after, cancellation, and health semantics; raw provider details do not leak to agent/public/iOS surfaces. |
| PMBD-6 | Auth Custody and Secret Safety | 10 | passed | Provider factory reloads credentials from auth custody, providers keep ephemeral credential copies, and provider audit/retry/failure/log surfaces redact or reject secret-bearing data. |
| PMBD-7 | Catalog, Routing, Model Limits, and Token Accounting | 8 | passed | Provider-specific registries remain authoritative; cross-provider helpers expose canonical IDs, capabilities, context windows, pricing, and server-authoritative token/cost records. |
| PMBD-8 | Provider Wire Confinement | 8 | passed | Static guards confine provider-native structs, JSON field names, aliases, beta headers, endpoints, and stream event names to provider-owned modules or documented protocol/catalog projections. |
| PMBD-9 | Negative and Adversarial Coverage | 8 | passed | Tests cover malformed stream/tool arguments, missing credentials, auth/provider errors, unsupported/wrong-provider models, cancellation during retry, redaction, oversized audit payloads, and stream parse failures. |
| PMBD-10 | Docs, README, Evidence, and Closeout | 7 | passed | README/progressive docs describe actual boundaries; evidence records exact commands; PMBD rows close at 100/100 after closeout verification. |

Total weight: **100**

## Closeout Notes

The main source change adds a shared foundation redactor, reuses it from the
event-store redaction module, bounds and redacts `model.provider_request` audit
payloads before persistence, and redacts provider-derived retry/failure/log
messages. Existing provider request shaping, stream normalization, id remapping,
catalog, auth custody, and token accounting architecture remains in place.

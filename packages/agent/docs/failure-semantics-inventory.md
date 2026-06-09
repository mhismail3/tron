# Failure Semantics Inventory

Status: **active**

This inventory tracks every current failure surface in scope for the Failure
Semantics Campaign. The TSV companion is the machine-readable version used by
static gates.

## Canonical Vocabulary

The canonical vocabulary is owned by
`packages/agent/src/shared/server/failure.rs`. Runtime-visible server failures
must map to one of these categories and one origin before they cross a live
event, engine transport, model responder, capability-result, durable-event, or
replay boundary.

| Category | Meaning |
|---|---|
| `invalid_request` | Client input, schema, JSON, or protocol validation failure. |
| `invalid_model` | Requested model id is unsupported. |
| `not_found` | Requested resource does not exist. |
| `unavailable` | Resource or feature is currently unavailable. |
| `conflict` | Idempotency, owner, busy, or state conflict. |
| `auth` | Authentication or authorization failure. |
| `network` | Network transport failure. |
| `rate_limit` | Provider or server throttling. |
| `api` | Provider API failure. |
| `parse` | JSON, SSE, or provider stream parsing failure. |
| `cancelled` | User/system cancellation. |
| `capability` | Model-requested primitive execution failure. |
| `engine` | Engine policy, routing, ledger, schema, or worker failure. |
| `persistence` | Event store, journal, ledger, replay, or storage failure. |
| `internal` | Unexpected server failure after sanitization. |
| `unknown` | Historical or imported failures that cannot be narrowed further. |

## Surface Inventory

| Surface | Current semantics | Required final state |
|---|---|---|
| `shared::server::failure::FailureEnvelope` | Canonical server envelope and vocabulary exist with stable code/category/message/retryable/recoverable/origin and optional provider/model/status/error type/retry-after/suggestion/details/references. | Keep as the single server-side failure contract; do not add parallel category taxonomies. |
| `shared::server::errors::CapabilityError` | Converts to/from `FailureEnvelope` while preserving stable code and structured details. | Add final static guards that active transports use the envelope conversion before emitting errors. |
| `shared::server::error_mapping` | Exhaustively maps every current `EngineError` variant; auth/session/event-store helpers still need explicit row-level mapping assertions. | Close FSC-3 with auth/session/event-store tests and uncovered-variant guards. |
| `engine::kernel::EngineError` | Rich variants now map to stable public failure code/category/retryability/recoverability through `engine_error_to_failure`. | Keep new variants covered by the mapping matrix. |
| `domains::model::providers::shared::ProviderError` | Produces canonical provider failures preserving provider, model, status, provider code, retry-after, retryable, recoverable, and cancellation. | iOS must consume the fields instead of reclassifying server-authored provider failures. |
| `domains::model::responder::ModelResponseError` | Carries a `FailureEnvelope` from provider/model boundary to agent runtime. | Remove or guard fallback conversions that lack provider/model context before closeout if still reachable. |
| `domains::agent::loop::RuntimeError` | Converts through canonical failure envelopes before live event emission. | Durable event payloads need the same envelope under FSC-9. |
| `TronEvent::TurnFailed` | Canonical builder populates code/category/retryable/recoverable/origin/details for active runtime paths. | Durable `turn.failed` payload enrichment remains FSC-9; optional fields remain for historical/imported rows until closeout policy is set. |
| `TronEvent::Error` | Canonical builder populates code/category/retryable/recoverable/origin/details plus provider/model/status/error type when present. | iOS decoding/projection parity remains FSC-8. |
| `capability.invocation.completed` | Error completions include `isError=true` and `details.failure` with the full canonical envelope. | Replay/export needs to retain the same details under FSC-9. |
| `/engine` WebSocket response errors | Error frames serialize the canonical failure envelope and retain outer trace id with sanitized public message. | Add source guard in FSC-10. |
| Durable error payloads | `error.agent`, `error.capability`, `error.provider`, and `turn.failed` have partial structured fields. | Persist canonical failure envelope or canonical fields with required code/category. |
| Replay manifest | Includes event and engine records but failure envelope is not yet explicit. | Replay/audit exports retain structured failure details for postmortem and deterministic inspection. |
| iOS engine protocol errors | Decodes code/message/details and keeps unknown codes. | Decode canonical fields and avoid inventing a divergent taxonomy when server fields exist. |
| iOS event projections and capability UI | Renders error code/details from event payloads and capability details. | Use server-provided canonical failure details for diagnostics and rendering. |

## Known Direct Construction Sites

- Production live `TurnFailed` constructors are now centralized in
  `shared::protocol::events::turn_failed_event`; remaining
  `TronEvent::TurnFailed` patterns are projections or tests.
- Production live `Error` constructors are now centralized in
  `shared::protocol::events::error_event`; remaining `TronEvent::Error`
  patterns are projections or tests.
- Text-only model capability `error_result` has been removed. Capability
  executor failures use `failure_result` with `details.failure`.
- `/engine` socket errors use `CapabilityError::to_failure` before serializing
  the response error object.

## Open Loops

- FSC-1 remains open until the iOS and durable replay changes land and this
  inventory is re-audited against source.
- FSC-3 still needs explicit auth/session/event-store mapping assertions and
  closeout guards for new enum variants.
- FSC-8 must audit iOS `ErrorClassification` and connection retry classifiers
  carefully. Transport/network reachability classifications may remain local
  when no server response exists; server-authored failure classifications must
  not be duplicated.
- FSC-9 must ensure durable event rows and replay manifests preserve
  `details.failure` or equivalent canonical fields for new failures.

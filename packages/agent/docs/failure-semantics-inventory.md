# Failure Semantics Inventory

Status: **closed/verified**

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
| `shared::server::errors::CapabilityError` | Converts to/from `FailureEnvelope` while preserving stable code and structured details. | FSC-10 guards active transports so they use the envelope conversion before emitting errors. |
| `shared::server::error_mapping` | Exhaustively maps every current `EngineError` variant and canonicalizes auth/session/event-store failures, including event-store busy/failure and auth storage/transport/OAuth cases with safe `details.failure`. | Keep new error variants covered by focused tests and static source guards. |
| `engine::kernel::EngineError` | Rich variants now map to stable public failure code/category/retryability/recoverability through `engine_error_to_failure`. | Keep new variants covered by the mapping matrix. |
| `domains::model::providers::shared::ProviderError` | Produces canonical provider failures preserving provider, model, status, provider code, retry-after, retryable, recoverable, and cancellation. | Keep provider consumers on the canonical envelope. |
| `domains::model::responder::ModelResponseError` | Carries a `FailureEnvelope` from provider/model boundary to agent runtime; provider stream parser errors are converted at this boundary with provider/model identity, and the generic unknown-provider conversion is deleted. | Keep provider/model-aware constructors as the only provider error path. |
| `domains::agent::loop::RuntimeError` | Converts through canonical failure envelopes before live event emission. | Active durable turn-failure writers now preserve the same envelope under `details.failure`. |
| `TronEvent::TurnFailed` | Canonical builder populates code/category/retryable/recoverable/origin/details for active runtime paths. | FSC-10 guards direct construction sites so active emitters stay on the canonical builder. |
| `TronEvent::Error` | Canonical builder populates code/category/retryable/recoverable/origin/details plus provider/model/status/error type when present. | FSC-10 guards direct construction sites and iOS consumers of `details.failure`. |
| `capability.invocation.completed` | Error completions include `isError=true` and `details.failure` with the full canonical envelope; durable/replay exports retain the same structured details. | Keep future capability completion writers on `details.failure`. |
| `/engine` WebSocket response errors | Error frames serialize the canonical failure envelope and retain outer trace id with sanitized public message. | FSC-10 guards the source frame shape and Swift decoder parity. |
| Durable error payloads | `error.agent`, `error.capability`, `error.provider`, and `turn.failed` accept canonical fields; active interrupted `turn.failed` rows store `details.failure`. | Keep future durable failure writers on the canonical envelope. |
| Replay manifest | Session event payloads remain raw durable truth; engine invocation errors export `error.failure` plus replay-local diagnostic fields. | Keep new replay failure sections on canonical envelopes. |
| iOS canonical failure DTO | `CanonicalFailurePayload` decodes the server envelope from `/engine` errors and `details.failure`. | Keep as the only Swift representation of server-authored failure semantics. |
| iOS engine protocol errors | Decode the full canonical envelope and expose `failure`; child engine invocation errors must carry `details.failure` or the client treats the response as invalid. | FSC-10 guards `/engine` error decoding against code/message-only regressions. |
| iOS event projections and capability UI | Live `error`/`agent.turn_failed`, persisted `error.*`/`turn.failed`, provider pills, session summaries, expanded content, and capability error rows prefer `details.failure`. | FSC-10 guards live failure plugins and display classification against divergent taxonomy. |

## Allowed Direct Construction Sites

- Production live `TurnFailed` constructors are now centralized in
  `shared::protocol::events::turn_failed_event`; allowed
  `TronEvent::TurnFailed` patterns are projections or tests.
- Production live `Error` constructors are now centralized in
  `shared::protocol::events::error_event`; allowed `TronEvent::Error`
  patterns are projections or tests.
- Text-only model capability `error_result` has been removed. Capability
  executor failures use `failure_result` with `details.failure`.
- `/engine` socket errors use `CapabilityError::to_failure` before serializing
  the response error object.

## Closeout Notes

- FSC-1 source coverage is enforced by the TSV path-existence and stale-marker
  guards.
- FSC-3 mapping coverage is enforced for current engine, auth, session, and
  event-store error sources.
- FSC-8 iOS parity is enforced for server-authored live failure events,
  `/engine` errors, and capability error display data.
- FSC-9 durable/replay parity is enforced for active durable turn failures,
  capability completion details, and replay engine invocation failures.

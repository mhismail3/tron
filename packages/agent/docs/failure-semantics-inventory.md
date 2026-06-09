# Failure Semantics Inventory

Status: **active**

This inventory tracks every current failure surface in scope for the Failure
Semantics Campaign. The TSV companion is the machine-readable version used by
static gates.

## Vocabulary Draft

The final canonical vocabulary will be owned by the server-side failure
envelope. Until FSC-2 lands, these values are provisional inventory labels:

| Category | Meaning |
|---|---|
| `invalid_request` | Client input, schema, JSON, or protocol validation failure. |
| `not_found` | Requested resource does not exist. |
| `conflict` | Idempotency, owner, busy, or state conflict. |
| `auth` | Authentication or authorization failure. |
| `provider` | Provider API, model, auth, network, rate-limit, parse, or cancellation failure before canonical provider subcategory mapping. |
| `network` | Network transport failure. |
| `rate_limit` | Provider or server throttling. |
| `cancelled` | User/system cancellation. |
| `capability` | Model-requested primitive execution failure. |
| `engine` | Engine policy, routing, ledger, schema, or worker failure. |
| `persistence` | Event store, journal, ledger, replay, or storage failure. |
| `internal` | Unexpected server failure after sanitization. |
| `unknown` | Historical or imported failures that cannot be narrowed further. |

## Surface Inventory

| Surface | Current semantics | Required final state |
|---|---|---|
| `shared::server::errors::CapabilityError` | Stable code and optional details, but no canonical category, retryability, recoverability, or origin. | Convert to/from canonical failure envelope without dropping code/details. |
| `shared::server::error_mapping` | Maps selected engine/event-store/auth errors to `CapabilityError`; fallback still collapses many `EngineError` variants to `INTERNAL_ERROR`. | Exhaustive matrix with stable code/category/details for every in-scope source error. |
| `engine::kernel::EngineError` | Rich variants but no direct canonical failure conversion. | Every variant maps to a stable public code/category/retryability/recoverability. |
| `domains::model::providers::shared::ProviderError` | Has category, retryable, retry-after, status, provider code, and cancellation across variants, but not one envelope. | Preserve provider, model, status, provider code, retry-after, retryable, recoverable, and cancellation through model/runtime. |
| `domains::model::responder::ModelResponseError` | Carries message/category/retryable/cancelled only. | Carry canonical failure fields from provider boundary to agent runtime. |
| `domains::agent::loop::RuntimeError` | Has category/recoverability, no stable public code/details/origin. | Convert through canonical builder before live/durable/UI emission. |
| `TronEvent::TurnFailed` | Optional code/category and direct construction in active runtime paths. | Server builders always populate canonical failure fields. |
| `TronEvent::Error` | Optional structured fields and direct construction in service helpers. | Server builders always populate canonical failure fields. |
| `capability.invocation.completed` | `isError` and optional details exist; executor can collapse engine errors into plain text. | Error completions include structured failure details while preserving model-visible text. |
| `/engine` WebSocket response errors | Sanitized message, code, details, and trace id are present. | Add canonical category, retryable, recoverable, origin, and safe references consistently. |
| Durable error payloads | `error.agent`, `error.capability`, `error.provider`, and `turn.failed` have partial structured fields. | Persist canonical failure envelope or canonical fields with required code/category. |
| Replay manifest | Includes event and engine records but failure envelope is not yet explicit. | Replay/audit exports retain structured failure details for postmortem and deterministic inspection. |
| iOS engine protocol errors | Decodes code/message/details and keeps unknown codes. | Decode canonical fields and avoid inventing a divergent taxonomy when server fields exist. |
| iOS event projections and capability UI | Renders error code/details from event payloads and capability details. | Use server-provided canonical failure details for diagnostics and rendering. |

## Known Direct Construction Sites

- `packages/agent/src/domains/agent/loop/turn_runner/mod.rs` constructs
  `TronEvent::TurnFailed` directly for engine surface, model audit, audit
  persistence, model response, journal, stream, and assistant persistence
  failures.
- `packages/agent/src/transport/runtime/streams/turn.rs` projects optional
  `TurnFailed` code/category into server event data.
- `packages/agent/src/transport/runtime/streams/session/agent.rs` and
  `packages/agent/src/domains/agent/runtime/service/{agent_build,completion}.rs`
  construct or project live `TronEvent::Error`.
- `packages/agent/src/domains/agent/loop/capability_invocation_executor/mod.rs`
  uses text-only `error_result` for several executor failures.
- `packages/agent/src/transport/engine/socket/mod.rs` builds WebSocket error
  frames from `CapabilityError` without canonical category/retryability fields.

## Open Loops

- FSC-2 must choose the exact Rust home for the canonical envelope. The current
  likely owner is `shared::server` because transport, domain capabilities,
  agent runtime, and model responder can all depend on it without importing one
  another.
- FSC-3 must decide whether `CapabilityError` becomes a thin wrapper around the
  canonical envelope or keeps its public enum while exposing envelope
  conversion.
- FSC-8 must audit iOS `ErrorClassification` and connection retry classifiers
  carefully. Transport/network reachability classifications may remain local
  when no server response exists; server-authored failure classifications must
  not be duplicated.

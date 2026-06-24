# Provider / Model Boundary Discipline Inventory

Status: **complete**
Machine-readable inventory:
[`provider-model-boundary-discipline-inventory.tsv`](provider-model-boundary-discipline-inventory.tsv)

## Taxonomy

- `boundary_root`: module that defines the canonical provider/model boundary.
- `provider_family`: provider-owned request, stream, error, auth, and catalog code.
- `protocol_helper`: shared model-protocol conversion helper allowed to know
  provider-native stream/tool concepts.
- `auth_custody`: credential ownership and provider factory handoff.
- `audit_replay`: durable provider request audit surface.
- `token_catalog`: model registry, capability flags, context limits, and
  token/cost normalization.
- `test_static_gate`: focused test or invariant that proves the boundary.
- `docs_ci`: documentation or closeout harness wiring.

## Summary

The current architecture keeps model providers behind two layers:

1. Provider modules implement `providers::shared::provider::Provider` and own
   their wire request/response DTOs, request builders, stream handlers, auth
   headers, provider error parsing, and provider-specific model metadata.
2. `domains::model::responder` is the non-provider composition boundary. It
   builds provider-neutral stream options, opens provider streams, wraps retry,
   maps provider errors to canonical failures, records provider health, and
   builds the versioned `model.provider_request` audit payload before streaming.

Provider-native capability argument parsing and invocation-id remapping are
allowed in `domains::model::protocol` because they are explicit conversion
helpers. Agent loop, runtime, public protocol, session replay, and iOS-facing
DTOs consume canonical `StreamEvent`, `FailureEnvelope`, `ModelProviderRequestAudit`,
catalog, and token records.

## Findings Closed

- Provider audit payloads are now redacted and size-bounded before persistence.
- Provider-derived retry/failure/stream-error messages use the shared redactor.
- Static gates reject provider-native imports and wire markers outside provider,
  protocol, routing, token, and documented replay/audit boundaries.
- Stale `codex/provider-model-boundary-discipline` artifacts were not adopted
  as proof because that branch is not on the reconciled PPACD/OPSAA lineage.

## Coverage Notes

The inventory covers all six provider families: OpenAI, Anthropic, Google,
Kimi, MiniMax, and Ollama. MiniMax intentionally reuses Anthropic-compatible
message and stream logic behind its own provider module; Ollama intentionally
uses the native local `/api/chat` boundary and has no credential custody.

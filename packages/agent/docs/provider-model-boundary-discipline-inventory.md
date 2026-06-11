# Provider / Model Boundary Discipline Inventory

This inventory records the provider/model boundary surfaces audited for PMBD.
The TSV is the machine-readable source; this file summarizes the taxonomy and
closure policy.

## Coverage Policy

- Provider-native request, header, base URL, beta flag, stream event, tool-call,
  and auth details belong under `packages/agent/src/domains/model/providers/`.
- Shared provider infrastructure may expose only the canonical provider trait,
  retry, SSE, stream, context composition, error parsing, and health helpers.
- The responder boundary is the only non-provider runtime surface that creates
  providers, opens streams, applies retry, records provider health, maps provider
  errors, and builds provider audit payloads.
- Model protocol helpers may own provider-native capability argument parsing and
  invocation id remapping, but agent history and public/iOS DTOs consume only
  canonical capability/history structs.
- Provider audit DTOs are protocol-owned because they are persisted and replayed
  without importing provider internals. Payloads must be redacted and bounded
  before persistence.
- Auth credentials remain the durable custody owner. Provider factories reload
  credentials from auth custody and pass only ephemeral in-memory copies into
  concrete providers.

## Surface Classes

| Class | Meaning |
| --- | --- |
| `model_domain_root` | Domain docs, contract, handlers, and deps for model capabilities. |
| `model_responder_boundary` | Canonical responder trait, request/response DTOs, provider creation, retry, health, error mapping, and audit construction. |
| `provider_shared_helper` | Provider-neutral helpers under `providers/shared/`. |
| `provider_family` | Concrete provider implementation family including request shaping, stream handling, types/catalogs, and tests. |
| `model_protocol_helper` | Provider-native capability parsing and deterministic id remapping boundary. |
| `routing_catalog_tokens` | Server-authoritative model registry, catalog projection, routing, context window, pricing, and token accounting. |
| `auth_custody` | Durable auth storage, credential resolution, refresh, and provider factory loading. |
| `failure_audit_event` | Canonical failure envelope, provider audit DTO, and event payload surfaces. |
| `agent_consumer` | Agent runtime/turn-runner model responder consumers. |
| `ios_projection` | Thin-client model/provider/auth/error/settings mirrors that must remain server-owned projections. |

## Closure

PMBD is closed only when the scorecard reaches 100/100, the invariant target is
wired locally and in GitHub static gates, provider-native imports and wire names
are statically confined, provider audit payloads are redacted and bounded, exact
closeout commands pass in this worktree, and this inventory remains synchronized
with README and evidence.

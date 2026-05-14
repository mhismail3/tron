# Capability UI And Engine Console

> Last verified: 2026-05-13

The iOS capability UI is a thin client over server-owned capability records. It
does not maintain a local tool catalog and does not choose capability bindings
locally. The server remains authoritative for registry contents, policy,
approval, audit redaction, plugin lifecycle, and execution.

## Server Boundary

`CapabilityClient` calls canonical engine functions:

- Model primitives: `capability::search`, `capability::inspect`, and `capability::execute`
- Console reads: `capability::status`, `capability::registry_snapshot`,
  `capability::audit_query`, `capability::binding_list`,
  `capability::plugin_list`, `capability::plugin_inspect`, and
  `capability::policy_get`
- Console mutations: `capability::binding_set`, plugin install/update/state,
  plugin promotion, conformance run, implementation state, and policy update

The client sends requested authority scopes through `EngineInvocationContext`.
Those scopes are narrow claims for the current admin/operator action; the
server still evaluates active profile/session/workspace policy before every
mutation and writes audit records for accepted and denied operations.

## DTOs

Capability DTOs live in
`Sources/Models/EngineProtocol/EngineProtocolTypes+Capability.swift`.
They mirror the durable registry and primitive response shapes:

- `CapabilityStatusDTO`
- `CapabilityRegistrySnapshotDTO`
- `CapabilityContractDTO`
- `CapabilityImplementationDTO`
- `CapabilityPluginManifestDTO`
- `CapabilityBindingDTO`
- `CapabilityInspectionDTO`
- `CapabilityExecutionDTO`
- `CapabilityProgramRunDTO`
- `CapabilityAuditEventDTO`
- `CapabilityPolicyDTO`

The DTOs preserve identifiers such as `contractId`, `implementationId`,
`pluginId`, `workerId`, `functionId`, `schemaDigest`, and catalog/registry
revision. UI code should render these identifiers directly or through generic
metadata; it should not map retired tool names into capability identity.

## Engine Console State

`EngineConsoleState` owns live console state:

- status and registry snapshot refresh
- capability search and inspect, with search state scoped to the Capabilities
  section rather than the global console load state
- redacted audit query refresh
- plugin, implementation, conformance, promotion, and binding state changes
  tracked through a local mutation state so an action failure does not replace
  the whole console load state
- program-runtime inspection and program execution
- read-only stale cache snapshots

The operator console asks the server for an explicit lexical-allowed capability
search policy when the local vector index is unavailable. This is a visible
degraded operator mode: search results show the degraded status and reason.
Agent/model capability search still follows the active profile policy and does
not inherit the console's degraded search allowance.
Server status refreshes keep metadata responsive and trigger vector warm-up
without requiring the console to wait for the embedding model on first use.

When the server is disconnected, the state object loads
`EngineConsoleCache.Snapshot` and marks it stale. Mutations must stay disabled
while stale because the cache is read-only and may not reflect current policy,
binding, approval, or plugin state.

Program execution is an inspect-to-run flow. `EngineConsoleState` first
inspects `program::run_javascript`, stores the returned inspection handle,
function revision, and schema digest, and only then lets `CapabilityClient`
submit `execute(mode: "program")`. A catalog revision change clears that
inspection and forces a fresh inspect before another run.

## Schema Forms

`CapabilitySchemaForm` is the shared schema model for generated capability
forms. It supports objects, nested objects, arrays, strings, integers, numbers,
booleans, enums, nullable fields, defaults, examples, required validation, and
unsupported-field reporting.

UI hints are derived from JSON Schema metadata and field names for paths, URLs,
secret references, command text, markdown, durations, file roots, and network
targets. Secret fields must render as references only; iOS must not invent or
store raw secret values.

## Rendering Rules

Chat capability invocations render from `CapabilityInvocationDisplayModel`.
The display model keeps the provider-visible primitive (`Search`, `Inspect`, or
`Execute`) as the prominent label and derives the follow-on detail from the
canonical capability payload: search query, inspected target, resolved contract,
or execute payload summary. Chat chips intentionally use the compact glassy
capsule treatment used elsewhere in Tron: one accent color per primitive,
inline duration or live spinner, and a chevron to the detail sheet. This keeps
the chip provider-neutral while still showing the concrete operation being
performed, such as `Execute process::run · cargo test`.

Invocation detail sheets use the same display model. The toolbar carries the
primitive icon and title, while the first card is only capability identity:
resolved capability, display name, category/source, plugin, status badge, and
duration. Request, result, approval, artifacts, logs, and error classification
are separated into sheet-native sections. Request cards show high-signal fields
such as command, query, URL, compact path, reason, and mode; result cards show
status plus domain-specific summaries such as stdout/stderr, file content, diff
text, entry counts, match counts, and child invocation counts. Raw request JSON,
raw result JSON/text, schema digest, trace id, binding decision, and other
debug identifiers live in a collapsed Technical section by default. Search
results summarize query, catalog revision, index/vector status, result count,
cursor state, and ranked hits. Inspect results summarize contract,
implementation, worker/plugin provenance, trust/health, binding decision,
execution requirements, schema digest, inspection handle, approval requirements,
and examples when available. Unknown result shapes still render through a
generic readable JSON/text block, with oversized structured output available in
Technical instead of taking over the primary sheet.

The current Engine Console is a sheet-native operator surface built from
capability cards, metric grids, status banners, section chips, generated action
rows, and detail sheets. It renders overview, capability search/inspect, a
program-run form backed by a fresh inspection handle, plugin lifecycle
summaries, worker health, binding summaries, profile policies, redacted audit
rows, trace summaries, primer inputs, and redacted program-run records.
The default section set is intentionally small: Overview, Capabilities, and
Program Runs. Advanced operator sections expose plugins, workers, bindings,
policies, audit, traces, and primer details behind an explicit Advanced toggle
so end users can test the system without thinking about policy internals.
Program-run rows include parent/root invocation ids, binding decision ids, trace
id, hashes, selected implementations, child invocations, approval state,
artifact/log counts, and compensation-attempt counts while payload details
remain redacted by default. Generated invoke/program forms and result renderers
use contract and implementation metadata, not retired built-in-name dispatch.
First-party and external capabilities may provide presentation hints, but those
hints are advisory metadata attached to capability records; the generic sheet
must remain useful without them.

Long contract, implementation, plugin, worker, trace, and schema identifiers
must wrap or truncate inside cards without overlapping neighboring controls.
Badge rows use a wrapping layout so multiple capability metadata labels remain
legible on phone-width screens.

Provider protocol terminology is confined to provider-boundary and transcript payloads.
Capability UI surfaces use `CapabilityIdentity` and registry DTOs as the active
model; events without capability identity are diagnostics, not inputs to
retired-name mapping.

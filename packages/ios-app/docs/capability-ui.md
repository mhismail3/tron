# Capability UI And Engine Console

> Last verified: 2026-05-12

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

The client sends internal authority scopes through `EngineInvocationContext`.
Those scopes are descriptive request metadata, not permission grants. The server
still evaluates the active profile/session/workspace policy before every
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
- `CapabilityAuditEventDTO`
- `CapabilityPolicyDTO`

The DTOs preserve identifiers such as `contractId`, `implementationId`,
`pluginId`, `workerId`, `functionId`, `schemaDigest`, and catalog/registry
revision. UI code should render these identifiers directly or through generic
metadata; it should not map retired tool names into capability identity.

## Engine Console State

`EngineConsoleState` owns live console state:

- status and registry snapshot refresh
- capability search and inspect
- redacted audit query refresh
- implementation state changes
- read-only stale cache snapshots

When the server is disconnected, the state object loads
`EngineConsoleCache.Snapshot` and marks it stale. Mutations must stay disabled
while stale because the cache is read-only and may not reflect current policy,
binding, approval, or plugin state.

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

The current Engine Console renders overview, capability search/inspect, plugin
summaries, binding summaries, and redacted audit rows. Future generated execute
forms and result renderers should use contract and implementation metadata, not
retired built-in-name dispatch. First-party capabilities may provide presentation hints,
but those hints are advisory metadata attached to capability records.

Provider protocol terminology is confined to adapter and transcript payloads.
Capability UI surfaces use `CapabilityIdentity` and registry DTOs as the active
model; events without capability identity are diagnostics, not inputs to
retired-name mapping.

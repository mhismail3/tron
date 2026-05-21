# Capability UI And Engine Console

> Last verified: 2026-05-21

The iOS capability UI is a thin client over server-owned capability records. It
does not maintain a local tool catalog and does not choose capability bindings
locally. The server remains authoritative for registry contents, policy,
approval, audit redaction, plugin lifecycle, and execution.

## Server Boundary

`CapabilityClient` calls canonical engine functions:

- Model primitive: `capability::execute`
- Operator catalog reads: `capability::search` and `capability::inspect`
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
- `PrimitiveSurfacePolicyDTO`
- `CapabilityExecutionPolicyDTO`

The DTOs preserve identifiers such as `contractId`, `implementationId`,
`pluginId`, `workerId`, `functionId`, `schemaDigest`, and catalog/registry
revision. UI code should render these identifiers directly or through generic
metadata; it should not map retired tool names into capability identity.
Search DTOs support both a single `query` and a bounded `queries` array; inspect
DTOs support both a single target and bounded `targets`. Batch responses are
still one capability primitive response, with per-query/per-target result
objects and shared catalog/index status.

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
Agent/model `execute` resolution still follows the active profile policy and
does not inherit the console's degraded search allowance.
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
The display model keeps provider-visible primitive identity in metadata, but the
chip's prominent label is the user-facing resolved capability name: `Search`,
`Inspect`, `Run Command`, `List Directory`, `Search Text`, `Send Notification`,
or a generic humanized id for plugin capabilities that do not declare a display
name. The code-styled detail that follows the bold label is only the
high-signal request input, such as a shell command, query, URL, compact path, or
program first line.

Chat chips intentionally use the compact glassy capsule treatment used
elsewhere in Tron: fixed-width icons so labels align across capabilities, a
smaller code-styled detail string, an elapsed/duration label that stays visible
at the trailing edge while the detail truncates, and a chevron to the detail
sheet. Chips take only the width they need until the request detail is too long,
then the detail truncates inside the available row width. Capability metadata
may include `presentationHints.displayName`, `presentationHints.chipTitle`,
`presentationHints.icon`, and `presentationHints.themeColor`; iOS treats those
as server-owned presentation hints and only maps them into native Tron
components. Execution identity, authority, approval, and lineage still come
from the typed capability identity and audit fields, not from presentation
hints. When an early `execute` event has not resolved the binding yet, the chip
uses the server-provided hint when available and otherwise derives a stable
generic color from the requested contract id in the submitted arguments so
running process, filesystem, notification, and other first-party capability
chips do not all collapse to the generic execute color.
`capability.invocation.generating` creates the chip immediately, before worker
dispatch completes; `started`, `progress`, and `completed` update that same
invocation id. While running, chips show live elapsed time from `generatedAt` or
`startedAt`; after completion they show the observed invocation span when it is
longer than the server-reported inner execution duration. The raw server
duration remains available in collapsed metadata for audit.
Parallel calls are ordered by event enqueue order, not completion order, so a
fast child cannot jump ahead of an earlier running invocation.

Invocation detail sheets use the same display model. The toolbar carries the
primitive icon and title, while the first card focuses on operator-readable
capability identity: friendly capability name, status and observed duration
pills, and a user-facing plugin/source label such as `File System
(First-party)` or `GitHub (MCP)`. Request, execution path, result, approval,
artifacts, logs, and error classification are separated into sheet-native
sections. Request, execution path, and result sections use the same
capability-owned sheet accent so a single invocation reads as one coherent
native surface; success and failure still appear in status/error badges rather
than changing the structural container color. Request cards show target
capability arguments such as command,
execution mode, query, URL, compact path, reason, and notable booleans/counts;
wrapper fields like `intent`, `target`, and `reason` remain visible only when
they help explain how the single `execute` primitive was used.

For `capability::execute`, orchestration diagnostics are first-class operator
signal, not raw debug trivia. The detail sheet renders a native `Execution Path`
section over the server-owned details: resolution mode, selected target,
selected implementation, binding policy, catalog/schema revision, risk/effect,
payload/freshness/approval state, corrections, child invocation lineage, status,
duration, exit code, timeout state, and truncation. Result cards show the
operator-relevant output itself: stdout/stderr, file content, diff text, entry
names, match previews, or another domain output preview. Raw request JSON, raw
result JSON/text, trace id, binding ids, full schema hashes, and other forensic
identifiers remain available in the collapsed Metadata section.

Search results summarize query, catalog revision, index/vector status, result
count, cursor state, and ranked hits. Inspect results summarize contract,
implementation, worker/plugin provenance, trust/health, binding decision,
execution requirements, schema digest, inspection handle, approval requirements,
and examples when available. Unknown result shapes still render through a
generic readable JSON/text block, with oversized structured output available in
Metadata instead of taking over the primary sheet.

Capability discovery includes `AgentCapabilityRecipeDTO` on search hits and
inspection details. The UI can show these recipes as operator help, but it must
not maintain a parallel static capability catalog: recipe text, execute
templates, required/optional payload fields, lifecycle notes, approval behavior,
and result expectations all come from the live registry projection that also
feeds the model primer.

The current Engine Console is a sheet-native operator surface built from
capability cards, metric grids, status banners, section chips, generated action
rows, and detail sheets. It renders overview, operator capability search/inspect, a
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

Generated UI surfaces are not used for chat execution forensics in this phase.
The generated UI system remains server-authored and fixed-catalog for operator
actions and resource surfaces. A future server-authored execution surface may
reuse the same `ui_surface` substrate, but an agent must never custom-author
which execution evidence is shown after a run; the native detail renderer keeps
the audit path consistent across providers and capability kinds.

Long contract, implementation, plugin, worker, trace, and schema identifiers
must wrap or truncate inside cards without overlapping neighboring controls.
Badge rows use a wrapping layout so multiple capability metadata labels remain
legible on phone-width screens.

Provider protocol terminology is confined to provider-boundary and transcript payloads.
Capability UI surfaces use `CapabilityIdentity` and registry DTOs as the active
model; events without capability identity are diagnostics, not inputs to
retired-name mapping.

## Interactive And Async Lifecycle

Interactive, approval-gated, streaming, and long-running capabilities use the
same generic lifecycle model. `capability.pause.requested` creates a
`CapabilityPauseRecord` with a `pauseId`, `invocationId`, lifecycle kind,
resume schema, expiry, trace id, and binding decision id. The client renders
the generic pause sheet from that record and optional presentation hints. A
resume action must echo the exact `pauseId` and `invocationId`; once the server
accepts or rejects it, `capability.pause.resolved` updates the sheet and chip.
Duplicate, late, expired, cross-session, or offline submissions are local
errors until the server can validate them.

Async capabilities use `capability.run.status` and `CapabilityRunRecord`
updates. Chips and sheets show the run handle, status, child invocations, stream
topic, trace link, and final result without capability-specific renderer
dispatch. Subagent, background job, display/computer-use, notification,
approval, and future plugin-defined interactions therefore share one UI state
machine: pending, submitting/running, paused, resumed, denied, expired,
cancelled, completed, and failed.

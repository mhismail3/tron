# Capability Modularity Scorecard

Status: **complete**

Current score: **100/100**

The modularity measurement slice is complete: inventory coverage is 188/188, kernel boundary lockdown, binding-policy evidence, adapter seam requirements, the first metadata-only shadow replacement trial, governed route records, context policy records, and Engine Cockpit visibility are source-backed. Live module-adapter replacement execution is tracked by the dynamic replacement scorecard and remains intentionally deferred until the supervised module runtime exposes a provider-safe projection call.

Source of truth: `packages/agent/src/domains/capability/operations/registry.rs`

Provider-visible surface: one tool, `capability::execute`

This scorecard makes true modularity measurable. Every current `capability::execute` operation is classified as intentionally engine-owned, governance-owned, record-plane custody, adapter-replaceable, module-owned, or deferred. The current slices add documentation, invariants, source-backed adapter seam contracts, governance-owned binding-policy records, a metadata-only `git_status` shadow trial, governed route records, a scoped `git_status` route seam, and a redacted cockpit projection for operator visibility; they do not add package installation, dependency restoration, network behavior, production deployment, or live module-adapter execution.

## Artifacts

- Machine-readable inventory: `packages/agent/docs/capability-modularity-inventory.tsv`
- Evidence manifest: `packages/agent/docs/capability-modularity-evidence-manifest.md`
- Static invariant test: `packages/agent/tests/capability_modularity_scorecard_invariants.rs`

## Ownership Classes

| Class | Meaning | Replacement rule |
|---|---|---|
| `kernel_locked` | Minimal engine substrate: diagnostics, scratch state, trace/log/catalog/replay trust surfaces. | Never module-routed in v1. A module may read safe projections, not take over the kernel responsibility. |
| `governance_locked` | Trust pipeline for future modularity: module registry, authoring, validation, install, dependency, capability binding, lifecycle, runtime, procedural activation, and worker provenance. | Never silently module-routed in v1 because it governs replacement itself. |
| `record_plane` | Durable custody records and provider-safe projections. | Modules may add producers or workflows, but must not bypass server-owned records, resource refs, trace refs, or redaction. |
| `adapter_replaceable` | Built-in adapters that can eventually move behind binding policy. | Future modules may shadow or replace only through exact authority, evidence, rollback, and parity contracts. |
| `module_owned` | Capability already owned by a governed module/runtime pack. | Treated as the template for future replacements; must keep lifecycle/runtime prerequisites visible. |
| `deferred` | Classification intentionally left open. | Not used in this baseline; adding it must include a follow-up reason. |

## Scoring Rubric

Each operation is scored from 0 to 3 across contract, authority, evidence, provider safety, replay, binding, rollback, visibility, and tests.

- `0`: absent or intentionally unavailable for the class.
- `1`: documented only.
- `2`: implemented and partially tested.
- `3`: implemented, tested, visible, and enforced by invariants.

A `0` is acceptable for binding and rollback on `kernel_locked` and `governance_locked` rows because those classes are intentionally not routed through module replacement. For `adapter_replaceable`, a low binding or rollback score is a known gap, not acceptance.

## Baseline Coverage

| Ownership class | Operations |
|---|---:|
| `kernel_locked` | 11 |
| `governance_locked` | 71 |
| `record_plane` | 71 |
| `adapter_replaceable` | 31 |
| `module_owned` | 4 |
| `deferred` | 0 |

## Family Coverage

| Family | Operations | Default decision |
|---|---:|---|
| `capability_binding` | 24 | Governance substrate for metadata-only binding requests, decisions, policies, the `git_status` shadow trial, and scoped route records; live module-adapter execution remains deferred. |
| `catalog_discovery` | 3 | Engine-owned catalog trust and freshness substrate. |
| `context_control` | 12 | Record-plane snapshot/action/epoch and survivor/exclusion policy custody; the compaction summarizer strategy is replaceable only behind a server-owned context-audit and policy-snapshot seam. |
| `core` | 3 | Kernel diagnostics plus adapter review for `process_run`. |
| `device` | 4 | Device token custody is governance; safe inspection is record-plane. |
| `filesystem` | 9 | Adapter-replaceable after exact root authority, preview/commit evidence, bounded file side effects, provider-safe refs, replay/idempotency, and rollback/disable prerequisites. |
| `git` | 7 | Adapter-replaceable after exact repository authority, HEAD/index evidence, guarded Git side effects, provider-safe refs, replay/idempotency, and rollback/disable prerequisites. |
| `goals_questions` | 8 | Record-plane lifecycle custody; modules may extend workflows. |
| `import_history` | 3 | Record-plane import custody. |
| `import_preview` | 3 | Record-plane preview custody. |
| `jobs` | 5 | Adapter-replaceable behind supervised runtime authority, lifecycle evidence, bounded job side effects, provider-safe refs, replay/idempotency, and rollback/disable prerequisites. |
| `logs` | 1 | Engine-owned filtered log substrate. |
| `media` | 4 | Record-plane media custody. |
| `memory` | 7 | Record-plane evidence today; future retrieval/retention needs activation policy. |
| `module_authoring` | 3 | Governance substrate for proposal records. |
| `module_dependencies` | 9 | Governance substrate for dependency policy. |
| `module_install` | 6 | Governance substrate for install gates. |
| `module_lifecycle` | 4 | Governance substrate for lifecycle gates. |
| `module_program_execution` | 4 | Already module-owned execution pack template. |
| `module_registry` | 2 | Governance substrate for module manifests. |
| `module_runtime` | 4 | Governance substrate for runtime supervision. |
| `module_validation` | 3 | Governance substrate for validation gates. |
| `notifications` | 5 | Delivery policy is governance; inbox records are record-plane. |
| `procedural` | 9 | Governance for future learned behavior activation. |
| `program_execution` | 3 | Record-plane program-execution metadata custody. |
| `prompt_artifacts` | 3 | Record-plane prompt-artifact custody. |
| `repository_tree` | 3 | Record-plane repository-tree custody. |
| `scheduler` | 5 | Record-plane schedule custody; modules may extend workflows. |
| `state` | 3 | Session scratch-state primitive stays engine-owned until a later state/memory plane supersedes it. |
| `subagents` | 6 | Execution adapter can become replaceable only with exact task/runtime/job authority, merge evidence, bounded subagent side effects, provider-safe refs, replay/idempotency, and rollback/disable prerequisites; task records stay record-plane. |
| `tool_sources` | 2 | Governance/provenance, inspect-only. |
| `trace` | 2 | Engine-owned audit substrate. |
| `update_diagnostics` | 3 | Record-plane diagnostic custody. |
| `web` | 5 | Adapter-replaceable only with exact network authority, robots/source evidence, fail-closed side effects, provider-safe refs, replay/idempotency, and rollback/disable prerequisites. |
| `web_research` | 9 | Record-plane research custody; live research modules need binding policy. |
| `worker_packages` | 2 | Governance/provenance for worker packages. |

## Scorecard

| ID | Check | Weight | Status | Evidence |
|---|---|---:|---|---|
| CMS-0 | Registry/dispatch baseline | 10 | passed | 188 registry names and 188 dispatch arms are statically compared. |
| CMS-1 | Ownership taxonomy | 10 | passed | Six explicit classes and deterministic prefix grouping define what may and may not be module-routed. |
| CMS-2 | Per-operation inventory | 20 | passed | `capability-modularity-inventory.tsv` lists all 188 operations exactly once. |
| CMS-3 | Kernel/governance lock | 12 | passed | Invariant test rejects binding/rollback routes for locked rows and checks source-backed kernel boundary anchors. |
| CMS-4 | Adapter replacement targets | 12 | passed | Filesystem, Git, jobs, process, web, subagent, and compaction strategy seams name authority, evidence, side-effect, provider-safety, replay/idempotency, and rollback/disable prerequisites; capability binding can record proposals, shadow trials, and governed route controls, while live module-adapter execution remains deferred. |
| CMS-5 | Record-plane custody | 10 | passed | Record-plane rows require durable custody semantics and reject raw storage bypass as the replacement model. |
| CMS-6 | Module-owned template | 8 | passed | `module_program_execution_*` is classified as the first governed module-owned execution template. |
| CMS-7 | Cockpit visibility contract | 8 | passed | `capability_binding::cockpit_overview` projects truthful total/returned operation counts, operation-list/resource-scan completeness, redacted operation owner and replacement-target summaries, server-derived readiness/next-action labels, scoped binding/shadow attempts, rollback/disable/abort availability, and redaction policy for cockpit clients. |
| CMS-8 | Docs and static gates | 10 | passed | README links, evidence manifest, and invariant tests lock the inventory baseline, Kernel Boundary Lockdown evidence, and capability-binding governance semantics. |

## Kernel Boundary Lockdown Evidence

This follow-on slice records source-backed evidence for the substrate that must not be adapter/module-routed without a future scorecard and binding-policy change.

| Area | Lock |
|---|---|
| `authority/grants` | Engine-owned grant resolution and least-privilege authority stay outside module replacement. |
| `event/session log` | Session event/log truth, deterministic reconstruction, and append-only lifecycle semantics stay server-owned. |
| `resource store` | The generic typed resource store remains the durable custody substrate; record-plane producers must not bypass it. |
| `redaction/provider-safety` | Shared redaction and provider-safe projections remain kernel/governance requirements for visible evidence. |
| `trace/audit/replay/catalog` | Trace, replay manifest, and catalog discovery remain engine-owned audit/discovery substrate, not invocation routes. |
| `transport boundary` | `/engine` and `/engine/workers` stay authenticated transport framing over canonical engine requests, not domain behavior. |
| `module governance pipeline` | Module registry, authoring, validation, install, dependency, capability binding, lifecycle, runtime, procedural/tool-source/worker provenance gates remain governance-owned. |

## Binding Policy Evidence

The Capability Binding Policy slice adds a governance-owned record plane for future replacement proposals and route governance.

| Record | Evidence |
|---|---|
| `capability_binding_request` | Stores target operation, current built-in owner, requested replacement/extension target, ownership class, binding mode, actor scope, rationale, contract evidence refs, authority constraints, stale-version guards, rollback/disable refs, safe audit refs, and idempotency fingerprint. |
| `capability_binding_decision` | Revalidates exact request selectors and expected request version, records approved-policy or rejected decision evidence, requires denial evidence for rejections, and preserves request operation/binding/requirements without routing. |
| `capability_binding_policy` | Activates approved metadata policy after exact decision selector and expected decision version checks; activation carries rollback/disable refs and side-effect proof with `runtimeRoutingEnabled: false`. |

Provider-visible binding operations are limited to request/decision/policy record, list, inspect, and policy activation through `capability::execute`. They require explicit `capability_binding.read` / `capability_binding.write` plus resource authority, exact linked-resource selectors for inspect/decision/policy writes, non-wildcard selectors, `networkPolicy: none`, bounded provider-safe projections, idempotency, and stale-version guards. `kernel_locked` and `governance_locked` operations cannot request `replace`; `adapter_replaceable` and `module_owned` replacement requests require rollback/disable metadata and remain metadata-only proposals.

Binding policy records do not mutate dispatch, hot-swap modules, install/activate packages, execute modules, restore dependencies, run package managers, access networks, inherit `agent_state`, or expose raw paths/secrets/commands/logs/grant IDs/authority IDs/debug payloads.

## Shadow Replacement Trial Evidence

The Shadow Replacement Trial slice proves one low-risk metadata-only replacement path for `git_status`, the read-only Git status operation selected from the adapter-replaceable Git family.

| Record | Evidence |
|---|---|
| `capability_shadow_trial_request` | Stores the exact `git_status` target, authoritative built-in owner/class/target metadata, deterministic metadata-only candidate adapter description, exact-selector authority constraints, stale-version guard, rollback/disable/abort refs, safe audit refs, idempotency fingerprint, and `networkPolicy: none`. |
| `capability_shadow_trial_decision` | Revalidates the exact request selector and expected request version before approving, rejecting, disabling, or aborting the trial gate; it records decision evidence without enabling runtime routing. |
| `capability_shadow_trial_run` | Revalidates the exact approved decision selector and expected decision version, records a metadata-only run result, preserves rollback/disable/abort controls, and proves the candidate was not executed. |
| `capability_shadow_trial_evidence` | Stores bounded provider-safe built-in and deterministic candidate `git_status` projections plus server-computed comparison evidence; exact evidence inspection rejects stale expected evidence versions. |

Provider-visible shadow-trial operations are limited to request/decision/run record and evidence inspect through `capability::execute`. They require explicit `capability_binding.read` / `capability_binding.write` plus resource authority, non-wildcard kind selectors, exact linked-resource selectors, exact metadata selectors in the request, `networkPolicy: none`, no `agent_state` inheritance, no raw commands/logs/paths/files/grant IDs/authority IDs, idempotency, stale-version guards, and rollback/disable/abort refs. They do not execute candidate modules, re-run built-in Git behavior, mutate dispatch, route execution, hot-swap modules, install or activate packages, restore dependencies, run package managers, or access networks.

## Governed Route Record Evidence

The Dynamic Replacement slice adds scoped route records for the first read-only target, `git_status`. These records make routing state durable and reversible without teaching the dispatcher domain-specific module behavior.

| Record | Evidence |
|---|---|
| `capability_replacement_candidate` | Stores a validated/rejected/disabled candidate contract for exactly `git_status`, including owner label, module/runtime/lifecycle refs, schema/effect/risk evidence, authority constraints, rollback controls, safe audit refs, idempotency, and `networkPolicy: none`. |
| `capability_route_binding` | Links a validated candidate to a scoped route version after exact candidate selector and expected-version checks. |
| `capability_route_activation` | Activates a scoped route only after a ready binding, approval refs, rollback/disable controls, exact scope, and current binding version are present. |
| `capability_route_event` | Records activation, disable, rollback, and routed-invocation events as durable trace-linked route evidence. |
| `capability_route_rollback` | Records deterministic built-in restoration proof for route rollback. |

The current dispatcher seam resolves an active scoped `git_status` route and annotates the built-in provider-safe projection with route evidence. It fails closed on stale, disabled, missing-authority, missing-lifecycle, or unsafe route records. It does not yet invoke a live module-owned adapter projection; that missing projection call is the next dynamic replacement milestone.

## Cockpit Visibility Evidence

The Cockpit Visibility slice makes the scorecard inspectable from Engine Cockpit without exposing internal material or adding autonomy behavior.

| Projection | Evidence |
|---|---|
| `capability_binding::cockpit_overview` | System-visible pure-read function registered by the `capability_binding` domain with `capability_binding.read`, low risk, and no write capability. |
| Operation ownership | Joins `SUPPORTED_OPERATION_NAMES` and authoritative `operation_binding_metadata` with scoped binding/shadow-trial resources, so each operation reports a redacted current owner label, ownership status, built-in/module/locked flags, replacement/shadow/extension eligibility, redacted replacement target, readiness/next-action labels, and governance boundary from server truth. `capability_binding` is identified only as the cockpit projection source, not as the operation owner. |
| Scoped activity | Counts current-session/workspace binding requests, approvals, rejections, active policies, failed replacement attempts, shadow requests/approvals/rejections/runs/results, and rollback/disable/abort controls without returning raw resource IDs. The response separately reports total operations, returned operations, operation-list truncation, and bounded resource-scan completeness so small limits and capped scans cannot appear complete. |
| Redaction and side effects | Response policy declares projection-only, metadata-only, server-owned truth with no dispatch-table mutation, hot swap, module activation/execution, package-manager, dependency, network, raw local material, grants, authority IDs, trace IDs, invocation IDs, token-like material, or hidden chain-of-thought. |
| iOS rendering | Engine Cockpit keeps top-level summary compact and shows owner/status, replacement, attempts, rollback, and verification details only inside capability group and operation detail drill-down. |

## Adapter Seam Hardening Evidence

The Adapter Seam Hardening slice records source-backed replacement prerequisites for adapter-replaceable families and the compaction-like strategy seam. These contracts are documentation and metadata gates only; they do not add runtime routing.

| Family | Seam contract | Required replacement prerequisites |
|---|---|---|
| `filesystem` | exact root authority over the trusted runtime working directory plus preview/commit evidence parity. | bounded file side effects, provider-safe refs, replay/idempotency evidence, rollback/disable metadata, and no raw paths or file contents in provider-visible replacement records. |
| `git` | exact repository authority plus HEAD/index evidence parity. | guarded Git side effects, provider-safe refs, replay/idempotency evidence, rollback/disable metadata, and no remotes, hooks, checkout/reset/merge/rebase/push, or raw command/log exposure. |
| `process_run` | trusted working-directory authority, `networkPolicy none`, and bounded output. | bounded process side effects, provider-safe result projection, replay/idempotency evidence, rollback/disable metadata, and no network-capable shell replacement. |
| `jobs` | supervised runtime authority plus durable lifecycle evidence parity. | bounded job side effects, resource-backed job/output refs, provider-safe refs, replay/idempotency evidence, rollback/disable metadata, and no raw command/stdout/stderr/provider-visible job payloads. |
| `web` | exact network authority plus robots/source evidence parity. | fail-closed side effects, provider-safe refs, replay/idempotency evidence, rollback/disable metadata, and no search, crawl, browser automation, login/cookie reuse, or raw HTML dumps. |
| `subagents` | exact task/runtime/job authority plus reviewable merge evidence parity. | bounded subagent side effects, provider-safe refs, replay/idempotency evidence, rollback/disable metadata, no hidden parent-state mutation, and no inherited `agent_state`. |
| `context_control_compact` | summarizer strategy replacement only; context audit records, survivor/exclusion policies, and boundary commit stay server-owned. | provider-safe summary, context audit records, typed non-wildcard context policy refs, complete bounded policy snapshots, fail-closed proof before provider-context mutation, replay/idempotency evidence, rollback/disable metadata, and no raw prompt bodies, hidden chain-of-thought, secrets, local paths, commands, logs, grant IDs, or authority IDs. |

## Hard Rules

- `kernel_locked` operations must not be routed through module replacement.
- `governance_locked` operations must not be routed through module replacement; they are the trust pipeline for future replacement.
- Binding-policy records are governance-owned metadata only; an active policy is not a runtime route.
- Shadow-trial records are governance-owned metadata only; an accepted trial result is not a runtime route or replacement.
- Cockpit visibility is read-only projection over registry and scoped policy records; it must not become a routing, activation, or raw inspection surface.
- `adapter_replaceable` operations must name authority, evidence, side-effect, provider-safety, replay/idempotency, and rollback/disable constraints before any binding policy can route them.
- `record_plane` operations may gain module producers, but records, policy refs, resource refs, trace refs, redaction, and replay custody stay server-owned.
- `module_owned` operations must keep lifecycle/runtime prerequisites, inspectability, rollback, and provider-safe projections.
- `capability::execute` remains the only model-facing tool.

## Follow-on Slices

1. Kernel Boundary Lockdown: complete. Static/source-backed invariants now lock authority, event log, resource store, redaction, trace/audit, catalog, transport, and governance as non-replaceable substrate.
2. Capability Binding Policy: complete. Metadata-only binding request, decision, policy, and history records now make future replacement proposals measurable without routing.
3. Adapter Seam Hardening: complete. Source-backed invariants now lock seam prerequisites for filesystem, Git, jobs/process, web, subagent, and compaction-like strategies.
4. Shadow Replacement Trial: complete. `git_status` now has governed request/decision/run/evidence records comparing built-in and deterministic candidate provider-safe projections with rollback/disable/abort controls and no candidate execution.
5. Cockpit Visibility: complete. Engine Cockpit now reads `capability_binding::cockpit_overview` and progressively discloses total vs returned operations, list/scan completeness, redacted operation owner and replacement target, server-derived readiness/next action, built-in/module/locked status, replacement/shadow/extension eligibility, verification context, failed replacement attempts, shadow runs, and rollback/disable/abort availability without exposing raw internals.

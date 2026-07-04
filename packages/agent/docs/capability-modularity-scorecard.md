# Capability Modularity Scorecard

Status: active / capability-binding-policy-complete

Current score: inventory coverage 166/166; kernel boundary lockdown and binding-policy evidence are source-backed; replacement readiness is measurable without runtime routing.

Source of truth: `packages/agent/src/domains/capability/operations/registry.rs`

Provider-visible surface: one tool, `capability::execute`

This scorecard makes true modularity measurable. Every current `capability::execute` operation is classified as intentionally engine-owned, governance-owned, record-plane custody, adapter-replaceable, module-owned, or deferred. The current slices add documentation, invariants, and governance-owned binding-policy records only; they do not add runtime binding or routing behavior.

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
| `governance_locked` | 56 |
| `record_plane` | 64 |
| `adapter_replaceable` | 31 |
| `module_owned` | 4 |
| `deferred` | 0 |

## Family Coverage

| Family | Operations | Default decision |
|---|---:|---|
| `capability_binding` | 9 | Governance substrate for metadata-only binding requests, decisions, and policies; no runtime routing. |
| `catalog_discovery` | 3 | Engine-owned catalog trust and freshness substrate. |
| `context_control` | 5 | Record-plane epoch/action custody; compaction summarizer is replaceable behind a seam. |
| `core` | 3 | Kernel diagnostics plus adapter review for `process_run`. |
| `device` | 4 | Device token custody is governance; safe inspection is record-plane. |
| `filesystem` | 9 | Adapter-replaceable after exact filesystem authority, preview, and commit contracts. |
| `git` | 7 | Adapter-replaceable after exact repository authority, HEAD/index, and rollback contracts. |
| `goals_questions` | 8 | Record-plane lifecycle custody; modules may extend workflows. |
| `import_history` | 3 | Record-plane import custody. |
| `import_preview` | 3 | Record-plane preview custody. |
| `jobs` | 5 | Adapter-replaceable behind supervised job/runtime contracts. |
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
| `subagents` | 6 | Execution adapter can become replaceable; task records stay record-plane. |
| `tool_sources` | 2 | Governance/provenance, inspect-only. |
| `trace` | 2 | Engine-owned audit substrate. |
| `update_diagnostics` | 3 | Record-plane diagnostic custody. |
| `web` | 5 | Adapter-replaceable only with robots/source evidence parity. |
| `web_research` | 9 | Record-plane research custody; live research modules need binding policy. |
| `worker_packages` | 2 | Governance/provenance for worker packages. |

## Scorecard

| Item | Weight | Status | Evidence |
|---|---:|---|---|
| CMS-0 registry/dispatch baseline | 10 | Passed | 166 registry names and 166 dispatch arms are statically compared. |
| CMS-1 ownership taxonomy | 10 | Passed | Six explicit classes and deterministic prefix grouping define what may and may not be module-routed. |
| CMS-2 per-operation inventory | 20 | Passed | `capability-modularity-inventory.tsv` lists all 166 operations exactly once. |
| CMS-3 kernel/governance lock | 12 | Passed | Invariant test rejects binding/rollback routes for locked rows and checks source-backed kernel boundary anchors. |
| CMS-4 adapter replacement targets | 12 | Partially passed | Filesystem, Git, jobs, process, web, and subagent adapters name replacement targets; binding policy can record proposals but cannot route execution in this slice. |
| CMS-5 record-plane custody | 10 | Passed | Record-plane rows require durable custody semantics and reject raw storage bypass as the replacement model. |
| CMS-6 module-owned template | 8 | Passed | `module_program_execution_*` is classified as the first governed module-owned execution template. |
| CMS-7 cockpit visibility contract | 8 | Planned | README future-work notes point cockpit disclosure at owner, replacement, verification, and rollback state. |
| CMS-8 docs and static gates | 10 | Passed | README links, evidence manifest, and invariant tests lock the inventory baseline, Kernel Boundary Lockdown evidence, and binding-policy non-routing semantics. |

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

The Capability Binding Policy slice adds a governance-owned record plane for future replacement proposals only.

| Record | Evidence |
|---|---|
| `capability_binding_request` | Stores target operation, current built-in owner, requested replacement/extension target, ownership class, binding mode, actor scope, rationale, contract evidence refs, authority constraints, stale-version guards, rollback/disable refs, safe audit refs, and idempotency fingerprint. |
| `capability_binding_decision` | Revalidates exact request selectors and expected request version, records approved-policy or rejected decision evidence, requires denial evidence for rejections, and preserves request operation/binding/requirements without routing. |
| `capability_binding_policy` | Activates approved metadata policy after exact decision selector and expected decision version checks; activation carries rollback/disable refs and side-effect proof with `runtimeRoutingEnabled: false`. |

Provider-visible operations are limited to request/decision/policy record, list, inspect, and policy activation through `capability::execute`. They require explicit `capability_binding.read` / `capability_binding.write` plus resource authority, exact linked-resource selectors for inspect/decision/policy writes, non-wildcard selectors, `networkPolicy: none`, bounded provider-safe projections, idempotency, and stale-version guards. `kernel_locked` and `governance_locked` operations cannot request `replace`; `adapter_replaceable` and `module_owned` replacement requests require rollback metadata and remain metadata-only proposals.

This slice does not mutate dispatch, route execution, hot-swap modules, install/activate packages, execute modules, restore dependencies, run package managers, access networks, inherit `agent_state`, or expose raw paths/secrets/commands/logs/grant IDs/authority IDs/debug payloads.

## Hard Rules

- `kernel_locked` operations must not be routed through module replacement.
- `governance_locked` operations must not be routed through module replacement; they are the trust pipeline for future replacement.
- Binding-policy records are governance-owned metadata only; an active policy is not a runtime route.
- `adapter_replaceable` operations must name authority and evidence constraints before any binding policy can route them.
- `record_plane` operations may gain module producers, but records, resource refs, trace refs, redaction, and replay custody stay server-owned.
- `module_owned` operations must keep lifecycle/runtime prerequisites, inspectability, rollback, and provider-safe projections.
- `capability::execute` remains the only model-facing tool.

## Follow-on Slices

1. Kernel Boundary Lockdown: complete. Static/source-backed invariants now lock authority, event log, resource store, redaction, trace/audit, catalog, transport, and governance as non-replaceable substrate.
2. Capability Binding Policy: complete. Metadata-only binding request, decision, policy, and history records now make future replacement proposals measurable without routing.
3. Adapter Seam Hardening: document or introduce seams for filesystem, Git, jobs/process, web, and compaction-like strategies.
4. Shadow Replacement Trial: pick one low-risk read-only operation and prove built-in versus module-owned shadow execution, audit, visibility, and rollback.
5. Cockpit Visibility: show operation owner, built-in/module status, last verification, failed replacement attempts, and rollback availability through progressive disclosure.

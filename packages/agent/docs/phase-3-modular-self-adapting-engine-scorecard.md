# Phase 3 Modular Self-Adapting Engine Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**
Total weight: **100**

Planning baseline:
`main@bae6ddacd02bef1187118af00b19742aa3d5e7ac`
(`docs: accept phase 2 slice 22a`)

Historical comparison baseline:
`origin/next/modular-capability-engine@ad5e484722c6f7abbe764126409494026216ad92`

Companion artifacts:

- [`phase-3-modular-self-adapting-engine-evidence-manifest.md`](phase-3-modular-self-adapting-engine-evidence-manifest.md)
- [`phase-3-modular-self-adapting-engine-inventory.md`](phase-3-modular-self-adapting-engine-inventory.md)
- [`phase-3-modular-self-adapting-engine-inventory.tsv`](phase-3-modular-self-adapting-engine-inventory.tsv)

## Goal

Phase 3 restores the full modular-engine direction without rebuilding the old
branch as a fixed set of core domains and fixed iOS product panels. The target
architecture is:

- a small engine core that owns only provider boundaries, authority,
  resource/event/replay substrate, module supervision, storage primitives,
  and observability;
- modular capability packages that own feature behavior, dependency requests,
  package-specific resources, tests, docs, and lifecycle;
- agent-accessible authoring and improvement workflows for modules, governed by
  review, authority, dependency policy, validation, and rollback;
- an app surface that lets the user understand, steer, approve, and audit
  autonomous work without hardcoding every old feature as a native panel.

The old modular-capability branch is therefore a product feature inventory and
risk record, not the implementation template.

## Current Baseline

Phase 1 restored local iOS chat affordances and the generic runtime shell.
Phase 2 restored safe backend foundations for the old feature families:
capability execution, filesystem, jobs, git, web, goals, approvals, workers,
tool sources, subagents, procedural records, scheduling, notifications, media,
imports, repository metadata, update diagnostics, program-execution metadata,
prompt artifacts, provider reasoning status, memory query/decision evidence,
event/storage/settings/catalog parity, and dependency policy.

The current gap is not broad feature discovery. The current gap is ownership:
too many restored foundations are still compiled-in capability foundations
instead of installable, inspectable, agent-adaptable modules.

## Core Boundary

Phase 3 keeps these responsibilities in the engine core:

- provider/model boundary, redaction, token accounting, and no hidden
  chain-of-thought exposure;
- `capability::execute` dispatch, provider-visible schema bounding, and generic
  result transport;
- authority, grants, selectors, approvals, freshness, and denial evidence;
- resource type definitions, resource versions, lifecycle events, links,
  retention, leases, compensation, and replay refs;
- session event log, stream payload compatibility, trace/replay, and audit
  projection helpers;
- durable storage primitives, settings/profile primitives, auth custody, and
  dependency policy gates;
- worker/module supervisor primitives: launch envelope, cancellation, logs,
  quarantine, rollback, and health;
- generic observability channels consumed by iOS and future clients.

Everything else needs a module owner unless a slice proves it is a true
primitive.

## Modular Ownership Rule

A Phase 3 slice may add a new core primitive only when all of these are true:

1. Every future module needs the primitive.
2. The primitive can be expressed without product-specific behavior.
3. The primitive has deterministic tests, static inventory coverage, and
   explicit authority/resource boundaries.
4. The primitive cannot reasonably live inside a package without making safety,
   replay, or provider-boundary behavior weaker.

Feature behavior belongs in modules by default.

## First-Principles Implementation Standard

Every Phase 3 worker must start from the current product goal, not from old
code shape. A valid slice is:

- agent-first: designed around what an autonomous agent needs to inspect,
  decide, request, validate, execute, improve, and explain;
- user-governed: exposing the minimum facts and controls a user needs to
  understand, approve, interrupt, audit, or roll back autonomous work;
- minimal-core: keeping the engine limited to primitives all modules need;
- module-owned: placing feature behavior, dependencies, settings, resources,
  tests, docs, and UI facts under a named module owner;
- first-principles: defining data flow, authority, lifecycle, idempotency,
  replay, failure semantics, and redaction before coding;
- deduplicated: reusing established resource, authority, stream, trace,
  replay, settings, storage, validation, and cockpit projection patterns;
- discoverable: organizing files under clear module/domain ownership, updating
  `mod.rs` progressive docs, keeping submodule tables accurate, and splitting
  large owners before adding more behavior.

Phase 3 rejects legacy layering. Implementations must not wrap old shapes,
broad DTOs, stale adapters, compatibility shims, hidden fallback paths,
alternate unaudited code paths, client-owned server truth, duplicate helpers,
unused provider/schema variants, or dead code unless discovery proves a
concrete active compatibility requirement and review accepts that rationale.

These are acceptance criteria. A review may return `changes required` when an
implementation leaves duplicate paths, fallbacks, stale compatibility code,
dead code, poor file organization, or old fixed product architecture in place
even if focused tests pass.

## Scorecard

| Row | Name | Weight | Status | Evidence |
| --- | --- | ---: | --- | --- |
| P3MSA-0 | Source baseline and restoration goal | 7 | passed | Baseline commit, old-branch comparison point, Phase 1/2 ledgers, and Phase 2 closeout state are identified. |
| P3MSA-1 | Minimal core boundary | 9 | passed | Core-owned primitives are explicitly limited to provider, authority, resource/event/replay, storage, module supervision, and observability substrate. |
| P3MSA-2 | Module manifest and registry roadmap | 10 | passed | Slice 23A defines the manifest, registry, package identity, capability schema, resource declarations, authority needs, settings, dependency intents, provenance, and provider-safe inspection path. |
| P3MSA-3 | Agent self-authoring lifecycle roadmap | 10 | passed | Slices 23B through 23E define governed module proposal, workspace, validation, review, install, enable, disable, quarantine, and rollback flow. |
| P3MSA-4 | Authority, dependency, and sandbox roadmap | 10 | passed | Slices 23D, 23F, and 23G require scoped grants, approval gates, dependency review, sandbox envelopes, secrets separation, and fail-closed execution checks. |
| P3MSA-5 | Runtime execution and autonomy roadmap | 10 | passed | Slices 24A through 24C activate jobs/program execution, subagents, scheduling handoff, and result merge only through module-owned contracts. |
| P3MSA-6 | Memory and procedural learning roadmap | 9 | passed | Slices 24D and 24E separate memory retrieval/retention and procedural skills/rules/hooks from core while preserving audit, provenance, and user control. |
| P3MSA-7 | User cockpit and native surface roadmap | 10 | passed | Slice 23H establishes generic autonomous-work visibility before any workflow-specific native panel; later surfaces require stable module contracts and proof that generic rendering is insufficient. |
| P3MSA-8 | Slice execution protocol | 10 | passed | The plan defines discovery, implementation, independent review, focused fix, re-review, integration, validation, summary, next-discovery thread statuses, and first-principles/no-legacy acceptance rules for every slice. |
| P3MSA-9 | Validation and static-gate policy | 8 | passed | Each row includes expected focused tests plus shared gates for formatting, checking, docs/evidence, boundary discipline, organization, deduplication, dead-code rejection, personal-info guard, ignored files, and no repo-managed skills. |
| P3MSA-10 | Deferred and rejected old shapes | 7 | passed | The plan rejects speculative dependency restoration, broad DTO resurrection, fixed old iOS panels, public `/engine` expansion, repo-managed skills, and production deployment behavior. |

## Ordered Slice Roadmap

Each slice starts with an independent discovery thread even though this roadmap
is written up front. Discovery must restate the first-principles problem,
inspect current code/docs, confirm that the slice is still the smallest clean
next step, and either return exact final status `implementation may start` or
`blocked`. Discovery must also identify any duplicate, fallback, legacy, dead,
or poorly organized code in the touched area and decide whether the slice
removes it or records a precise reason it is outside scope.

### Slice 23A: Module Manifest And Registry Foundation

Objective: define the smallest source-backed module manifest and registry
contract that lets the engine inspect module identity, capabilities, resource
schemas, authority needs, settings, dependency intents, validation status, and
provenance without executing module behavior.

Minimal shape:

- module/package manifest schema;
- registry storage/resource records;
- provider-safe `module_list` and `module_inspect` or closest existing
  `capability::execute` operation values;
- static guard proving modules are inspectable without adding provider-visible
  tools beyond `execute`;
- docs that distinguish engine primitives from module-owned behavior.

Out of scope:

- installing new modules;
- executing module code;
- adding dependencies;
- repo-managed skills under `packages/agent/skills`;
- fixed iOS module marketplace UI.

Accepted Slice 23A closes `P3MSA-INV-001` as current baseline. It adds the
inspect-only `module_registry` domain, source-backed `module_manifest`
resources, provider-safe `module_list` and `module_inspect` execute operation
values, explicit read-only module/resource authority, exact module-manifest
selectors, and bounded lifecycle/provenance projections. It remains a registry
foundation only: no module install, module execution, dependency restoration,
repo-managed skills, public `/engine` expansion, marketplace UI, fixed native
panels, or production deploy/update behavior.

### Slice 23B: Module Authoring Workspace Foundation

Objective: create a governed place for agent-authored module proposals that is
not the core engine tree and not the old repo-managed skills directory.

Accepted Slice 23B closes `P3MSA-INV-002` as current baseline. It adds a
focused `module_authoring` domain backed by generic `module_proposal`
resources, with provider-visible `module_proposal_record`,
`module_proposal_list`, and `module_proposal_inspect` execute operations. It
keeps proposal state scoped to the current session/workspace, stores bounded
metadata/refs only, fingerprints idempotency and runtime refs, emits
`module_authoring.lifecycle`, and proves no install, activation, execution,
dependency restore, package-manager, network, physical workspace directory, or
repo-managed skills side effects. Review/fix loops hardened read-operation
unsafe-payload denial, provider-visible token-like metadata rejection,
trace-safe rejected-payload redaction, exact resource selectors, and SACB/PCC/
TPC inventory coverage before independent acceptance.

Minimal shape:

- proposal resource kind for module drafts;
- bounded source/doc/test refs rather than raw unbounded code payloads in
  provider-visible projections;
- record/list/inspect unsafe field and unsafe path denial, token-like identity
  and provider-visible metadata denial, idempotency evidence, lifecycle events,
  and fingerprinted trace/replay refs;
- read-only list/inspect operations for proposals with exact inspect-resource
  selectors.

Out of scope:

- automatic install;
- generated code execution;
- prompt injection from module drafts;
- unreviewed dependency additions.

### Slice 23C: Module Contract Test Harness

Objective: define how a module proves that its manifest, docs, tests, resource
schemas, provider projections, and authority declarations are internally
consistent before it can be installed or enabled.

Accepted Slice 23C closes `P3MSA-INV-003` as current baseline. It adds a
focused `module_validation` domain backed by generic
`module_validation_report` resources, with provider-visible
`module_validation_record`, `module_validation_list`, and
`module_validation_inspect` execute operations. It keeps validation evidence
scoped to the current session/workspace, stores bounded metadata/refs/checks
only, fingerprints idempotency and runtime refs, emits
`module_validation.lifecycle`, and proves no install, activation, execution,
command execution, dependency restore, package-manager, network, physical
workspace directory, or repo-managed skills side effects. Review/fix loops
refreshed SACB/TMB/PCC/TPC inventories and hardened provider-visible
command/result ref previews and summaries against raw shell command text before
independent acceptance.

Minimal shape:

- module validation report resource;
- deterministic validation command envelope;
- static checks for manifest/resource/schema/provider projection parity;
- docs/test requirements for each module;
- failure evidence that is bounded and provider-safe.

Out of scope:

- broad CI rewrite;
- runtime execution of arbitrary untrusted module code;
- accepting modules without deterministic validation evidence.

### Slice 23D: Module Review, Approval, And Install Gate

Objective: add the policy gate that turns a validated module proposal into an
install candidate only after explicit review, approval, authority, dependency,
and rollback checks.

Accepted Slice 23D closes `P3MSA-INV-004` as current baseline. It adds a focused
`module_install` domain backed by generic `module_install_request` and
`module_install_decision` resources, with provider-visible
`module_install_request_record`, `module_install_request_list`,
`module_install_request_inspect`, `module_install_decision_record`,
`module_install_decision_list`, and `module_install_decision_inspect` execute
operations. It keeps review-gate state scoped to the current session/workspace,
stores bounded metadata/refs only, requires current-scope passed
`module_validation_report` evidence with docs/tests and no-install/no-execution
proof, integrates existing approval freshness checks, requires derived
authority for decisions, emits metadata-only lifecycle states, and records
denial evidence for rejected/denied outcomes. The gate does not install,
activate, execute, restore dependencies, run package managers, access networks,
touch repo-managed skills, or update production.

Minimal shape:

- install-request and install-decision resources;
- approval integration with existing fail-closed approval checks;
- dependency-policy linkage to Slice 22A guard;
- explicit pending-review/install-candidate/rejected lifecycle states;
- reasoned denial evidence.

Out of scope:

- silent auto-install;
- dependency restoration without module owner;
- production update/deploy behavior;
- package signing trust beyond recorded provenance unless selected by discovery.

### Slice 23E: Module Enable, Disable, Quarantine, And Rollback

Objective: make module activation reversible and auditable before any module
executes meaningful work.

Accepted status: Slice 23E adds focused `module_lifecycle` metadata state
custody for install-candidate modules. It records
`module_lifecycle_state` resources for enable, disable, quarantine, and
rollback transitions through provider-visible `capability::execute` operations
`module_lifecycle_request`, `module_lifecycle_decision`,
`module_lifecycle_list`, and `module_lifecycle_inspect`. The implementation
requires explicit `module_lifecycle.read` / `module_lifecycle.write` plus
`resource.read` / `resource.write` grants, non-wildcard lifecycle resource-kind
selectors, exact lifecycle inspect/decision selectors, current-version
freshness, current-scope `module_install_decision` prerequisite revalidation,
fresh approval checks, bounded rollback proof refs/readiness, and
`networkPolicy: none`. It deliberately does not install, activate, execute,
restore dependencies, run package managers, touch repo-managed skills, expand
public `/engine`, or add fixed iOS UI.

Minimal shape:

- enable/disable/quarantine/rollback operations;
- state machine with version/freshness guards;
- bounded rollback proof and audit evidence refs;
- disabled/quarantined module denial path through lifecycle authorization;
- user-visible lifecycle events.

Out of scope:

- complex dependency graph resolution;
- live code execution side effects;
- native package-management UI beyond generic cockpit rendering.

### Slice 23F: Module Runtime Execution Supervisor

Objective: allow enabled modules to run through a generic supervisor that owns
process boundaries, cancellation, logs, stdout/stderr custody, leases,
timeouts, and cleanup, while module packages own feature semantics.

Minimal shape:

- execution envelope resource;
- sandbox/network/secrets policy labels;
- bounded log/output artifacts;
- cancellation/timeout/shutdown behavior;
- scoped module authority derivation;
- no provider-visible raw command/code/secret leakage.

Out of scope:

- PTY or interactive terminal by default;
- browser automation by default;
- language-specific interpreter restoration without module ownership;
- live network unless a module declares and is granted it.

Slice 23F is accepted current baseline for `P3MSA-INV-006`. It adds the
`module_runtime` domain, `module_runtime_state` resource schema, and
`module_runtime_request`, `module_runtime_list`, `module_runtime_inspect`, and
`module_runtime_cancel` execute operation values. Runtime requests require an
enabled current-scope `module_lifecycle_state` through the lifecycle
fail-closed authorization guard before any runtime record is created. The
recorded envelope stores sandbox, network, secrets, timeout, cancellation,
shutdown, scoped-authority, idempotency, trace/replay, bounded input/output
artifact refs, and side-effect proof metadata only. It deliberately does not
physically install modules, activate packages, restore dependencies, run
package managers, allocate PTYs, perform browser automation, access networks,
expose jobs directly as the provider-visible module surface, or store raw
commands, logs, stdout/stderr, code, file contents, paths, env values, secrets,
raw grant ids, or raw authority ids. The row is `current_baseline` after
independent re-review accepted the branch and mainline integration promoted it.

### Slice 23G: Module Dependency Request And Policy Activation

Objective: turn the Slice 22A dependency guard into a governed dependency
request path for modules.

Slice 23G is accepted current baseline for `P3MSA-INV-007`. It adds a focused
`module_dependencies` domain with generic resource-store-backed
`module_dependency_request`, `module_dependency_decision`, and
`module_dependency_policy` resources. Provider-visible access stays behind
`capability::execute` as `module_dependency_request_record`,
`module_dependency_request_list`, `module_dependency_request_inspect`,
`module_dependency_decision_record`, `module_dependency_decision_list`,
`module_dependency_decision_inspect`, `module_dependency_policy_activate`,
`module_dependency_policy_list`, and `module_dependency_policy_inspect`.
Requests carry owner/module linkage, dependency identity, rationale,
security/license/runtime need, removal plan, risk class, bounded refs,
Cargo.toml/Cargo.lock parity evidence, idempotency fingerprints, trace/replay
refs, side-effect proof, and `networkPolicy: none`. Decisions carry approved
policy or denial evidence, and policy activation makes only approved metadata
policy available for later module pack/runtime work. The accepted slice keeps
package-manager execution, dependency restoration, manifest/lockfile mutation,
runtime execution, raw artifacts/output/local material, network access, public
`/engine` expansion, and fixed native panels out of scope.

Minimal shape:

- dependency request resource;
- owner module linkage;
- rationale, security class, license class, runtime need, and removal plan;
- Cargo/package manifest parity guard;
- denial for high-risk removed dependencies without an approved module row.

Out of scope:

- speculative restoration of old dependency sets;
- adding portable PTY, browser automation, embeddings, APNs, interpreters, or
  signing packages without selected module scope and review.

### Slice 23H: Generic Autonomous Work Cockpit

Objective: give the user a coherent view of autonomous work without adding old
fixed product panels.

Minimal shape:

- generic activity timeline grouped by module, session, resource, approval,
  job, and error;
- active work summary, blocked/waiting states, authority labels, resource touch
  summaries, and rollback/quarantine status;
- iOS rendering from current server facts only;
- source guards preserving thin-client ownership.

Out of scope:

- fixed source-control, memory, process, subagent, notification, or skill
  panels;
- fake activity states;
- client-owned server truth.

Accepted status: Slice 23H moves `P3MSA-INV-008` to `current_baseline` after
independent re-review accepted the system-visible, inspect-only
`module_activity::overview` projection and its existing Runtime Cockpit Activity
tab rendering from server-owned module-plane facts. The accepted slice preserves
server-owned aggregation/redaction policy, thin iOS rendering, static guards,
documentation, and validation evidence without adding fixed product panels or a
provider-visible execute operation.

### Slice 24A: File And Source-Control Module Pack Activation

Status: accepted, current baseline.

Objective: declare existing filesystem and git foundations as a governed
module-owned workflow that supports reviewable file/git work without expanding
core or adding provider-visible tools.

Minimal shape:

- accepted Slice 24A `file_git_module` manifest seed, with module lifecycle
  `pending_review`, for the selected existing `filesystem_*` and `git_*`
  operation values;
- exact authority mapping for file and git operations through
  `capability::execute` runtime grants, trusted working-directory roots, and
  existing resource kinds;
- patch/materialized-file, Git index-change, commit, and branch-start resource
  evidence remains package-owned and bounded;
- optional native review surface remains deferred until generic cockpit
  insufficiency is proven.

Out of scope:

- arbitrary checkout, merge, rebase, reset, stash, fetch, pull, push, PR
  submission, or conflict resolution unless a later slice selects a narrower
  sub-slice;
- new public `/engine` methods, new provider-visible tools, package-manager or
  network behavior, raw path/env/secret/command/log/code/file-content exposure,
  and repo-managed `packages/agent/skills`.

### Slice 24B: Jobs And Program Execution Module Pack Activation

Status: accepted, current baseline.

Objective: connect durable jobs and program-execution metadata to a real
module-owned execution path with sandboxed runtime policy.

Accepted scope:

- accepted Slice 24B pending-review `jobs_program_execution_module` manifest
  declaring only
  `module_program_execution_start`, `module_program_execution_status`,
  `module_program_execution_cancel`, and `module_program_execution_cleanup`;
- module-owned runtime envelope that delegates non-interactive process work to
  the existing jobs runtime after enabled lifecycle authorization;
- content-free `program_execution_record` evidence linked to runtime/job/output
  refs, never raw command/code/stdin/stdout/stderr/log/path/env/pid material;
- exact authority selectors for module runtime, module lifecycle, program
  execution, job process, execution output, resource reads/writes, and trusted
  working-directory roots;
- provider-safe refs/fingerprints/truncation/duration/exit/timeout/
  cancellation/cleanup projections, trace-safe request/result redaction, and
  deterministic coverage for output custody and cleanup.

Out of scope:

- unconstrained shell;
- package install by default;
- PTY by default;
- network by default.
- fixed jobs/process cockpit panels;
- raw job_process or execution_output payload exposure.

### Slice 24C: Subagent Delegation Module Pack Activation

Objective: turn subagent task lifecycle records into real delegated work only
through enabled worker/module packages.

Status: accepted, current baseline.

Accepted scope activates only the accepted jobs/program-execution module pack
path with explicit
`workerKind: module_program_execution`, `modulePackId: jobs_program_execution`,
bounded handoff refs, delegated runtime/job/program refs, and reviewable
merge-proposal results.

Minimal shape:

- child-task launch contract;
- worker/module selection policy;
- bounded context handoff;
- status/result/cancel wiring;
- result merge proposal rather than silent parent mutation.

Out of scope:

- hidden autonomous spawning;
- unbounded prompt/context transfer;
- direct parent-state mutation without reviewable evidence.

### Slice 24D: Memory Retrieval And Retention Module Pack

Objective: add memory retrieval as a replaceable module engine instead of core
behavior.

Minimal shape:

- memory engine module manifest;
- retrieval query/result resources;
- ranking/provenance/confidence metadata;
- retention/edit/delete policy evidence;
- prompt-inclusion decision resource with user-visible proof.

Accepted Slice 24D records a pending-review `memory_engine_module` manifest and
keeps the behavior inside the existing
`capability::execute` memory audit surface. Retrieval is deterministic and
resource-backed over redacted `memory_record` previews only, with ranked refs,
confidence, provenance, bounded snippets, prompt-inclusion decision proof, and
retention/edit/delete policy evidence. It does not add embeddings, vector
indexes, generated summaries, automatic retention, public `/engine` methods,
fixed native panels, package-manager behavior, or network access.

Out of scope:

- embeddings/vector dependencies without module dependency approval;
- hidden prompt injection;
- invented summaries without source refs;
- automatic retention without policy and audit.

### Slice 24E: Procedural Skills, Rules, And Hooks Module Pack

Objective: make learned procedures and rules agent-authorable, testable,
reviewable, and reversible.

Minimal shape:

- procedure/rule/hook module contract;
- trigger declaration and authority scope;
- validation report;
- activation/deactivation lifecycle;
- provenance and user audit trail.

Accepted Slice 24E records a pending-review `procedural_module` manifest and
keeps procedural behavior inside the existing
`domains/procedural` resource owner. It adds metadata-only
`procedural_definition_record`,
`procedural_activation_request_*`, and `procedural_activation_decision_*`
execute surfaces backed by `procedural_record`,
`procedural_activation_request`, and `procedural_activation_decision`
resources. The slice records bounded validation evidence, review state, trigger
declarations, conflict/ordering metadata, scoped-authority proof, trace/replay
refs, rollback/deactivation proof refs, provider-safe projections, and
idempotency fingerprints while proving no hook firing, trigger registration,
prompt injection, dependency restoration, package-manager behavior, network
access, repo-managed skill copy, or code execution occurred.

Out of scope:

- repo-managed `packages/agent/skills` and bootstrap skill prompt context;
- hidden hook firing, automatic activation, or learned behavior without review;
- generated/runtime code execution, dependency restoration, package managers,
  or network access;
- raw commands, logs, paths, file contents, grant ids, authority ids, secrets,
  or debug payloads in provider-visible projections.

Out of scope:

- repo-managed bootstrap skills;
- hidden hook firing;
- prompt injection without explicit policy;
- learned behavior that bypasses review.

### Slice 24F: Web, Browser, And Research Module Pack

Objective: extend current web provenance foundations through modules for search,
crawling, browser automation, or logged-in session work only when selected and
authorized.

Minimal shape:

- separate module manifests for search, crawl, and browser automation;
- network authority and robots/citation policy;
- cookie/session custody rules;
- dependency requests for browser automation packages if needed.

Out of scope:

- broad browser automation in core;
- login/cookie reuse without explicit user authority;
- unbounded crawling;
- raw page dumps in provider-visible payloads.

### Slice 24G: Notifications And Device Delivery Module Pack

Objective: decide whether server notification resources should activate live
device delivery and native inbox behavior.

Minimal shape:

- APNs/delivery module manifest if selected;
- credential custody and entitlement proof;
- physical-device validation;
- native inbox only if backed by server notification facts;
- delivery failure evidence.

Out of scope:

- fake local inbox;
- raw token exposure;
- production push behavior without explicit environment and user decision.

Implementation-candidate Slice 24G records a pending-review
`notification_delivery_module` manifest only. It covers the existing
server-owned `device_registration`, `notification`, and `notification_delivery`
resources and existing device/notification execute operations, keeps the
trusted system/admin split for device register/unregister, declares
device/notification/resource authority needs bounded to the existing resource
kinds with `kind:device_registration`, `kind:notification`, and
`kind:notification_delivery` selectors, and keeps `networkPolicy: none`,
`installable: false`, and `executable: false`.

Pending acceptance gates remain APNs credential custody, APNs environment
labels, entitlement proof, physical-device validation, delivery-failure
evidence, provider redaction, and native inbox product decisions. Live APNs
transport, native inbox UI, entitlements, physical-device operations,
credential mutation, package-manager execution, network side effects, SQLite
migrations, public notification APIs, raw provider payloads, repo-managed
skills, and production deploy/update behavior remain out of scope.

### Slice 24H: Import, Repository, And Update Module Pack

Objective: decide which import/repository/update metadata foundations should
become real module workflows.

Minimal shape:

- module-owned import execution proposal;
- repository tree or update-diagnostic action contracts;
- approval and rollback policy;
- generic cockpit rendering first.

Out of scope:

- production update/deploy commands;
- raw repository tree dumps;
- installer/restart commands;
- native fixed panels without stable contracts.

Accepted Slice 24H records a pending-review
`import_update_module` manifest only. It covers existing
`import_history_record`, `repository_tree_snapshot`, `import_preview`, and
`update_diagnostic_record` resource foundations and existing import-history,
repository-tree, import-preview, and update-diagnostic record/list/inspect
execute operations. It declares kind-selector-bounded domain/resource authority
metadata, keeps `networkPolicy: none`, `installable: false`, and
`executable: false`, and preserves validation gates for approval, rollback,
future action contracts, bounded payload custody, and provider redaction.

Future activation gates remain actual import execution proposal resources,
repository tree action resources, update action/rollback execution, native
import/update UI, live update checks, and approved repository mutation
workflows. Import execution, repository mutation, raw tree dumps, raw
diagnostics payloads, package-manager behavior, installer/restart/update
commands, production deploy behavior, native fixed panels, public `/engine`
expansion, network behavior, and repo-managed skills remain out of scope.

## Execution Protocol

Every Phase 3 slice follows this thread sequence:

1. Discovery thread from clean `origin/main`.
   - Title: `Tron Phase 3 Slice <id> Discovery`.
   - Required final status: `implementation may start` or `blocked`.
   - Output: selected slice, baseline commit, recommended branch, exact scope,
     files likely touched, validation, out-of-scope list, user decisions, and
     deferred scope.
   - Required analysis: first-principles product goal, agent-first design,
     user-control needs, owning abstractions, duplicate/fallback/dead-code
     audit, file organization plan, and explicit rejection of old branch shape.
2. Implementation thread on one focused branch.
   - Branch format:
     `codex/phase-3-slice-<id>-<short-topic>`.
   - Required final status: `implementation complete` or `blocked`.
   - Must include code, focused tests, docs, README updates when source truth
     changes, static inventory/evidence updates, and no unrelated cleanup.
   - Must implement the clean minimal contract from first principles, keep code
     under clear module ownership, update progressive docs, split large owners
     before expanding them, deduplicate helpers, and remove dead/fallback/legacy
     paths introduced or made obsolete by the slice.
3. Independent adversarial review thread.
   - Required verdict: `slice accepted` or `changes required`.
   - Must compare `baseline..head`, verify branch/head/cleanliness/ancestry,
     inspect code/tests/docs/evidence, and run focused validation.
   - Must verify the implementation is agent-first, user-governed,
     first-principles, deduplicated, discoverable, well organized, and free of
     new legacy/fallback/dead code.
4. Focused fix thread when required.
   - Required final status: `fix ready for review` or `blocked`.
   - Must address only review findings with deterministic regression coverage.
5. Independent re-review thread.
   - Required verdict: `slice accepted` or `changes required`.
   - Loop with additional focused fix threads until accepted or blocked.
6. Mainline integration.
   - Merge accepted commits into `main`.
   - Update Phase 3 scorecard/inventory/evidence, README, and any touched
     static inventories with accepted wording.
   - Validate from `main`.
   - Push `main`.
   - Verify `HEAD == origin/main`.
   - Verify accepted commits are ancestors of `origin/main`.
7. Final summary and next discovery.
   - Start a summary thread with exact accepted commits, validation, deferred
     scope, and final status.
   - Start the next discovery thread from fresh `origin/main`.

## Shared Validation

Each implementation or review chooses the smallest useful validation set, but
the default Phase 3 closeout set is:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
- `cargo check --manifest-path packages/agent/Cargo.toml`
- focused Rust tests for touched domains/modules
- focused iOS tests and `xcodegen generate` when Swift or project files change
- `baseline_pre_restoration_closure_invariants`
- `documentation_evidence_scorecard_integrity_invariants`
- `self_sufficient_agent_runtime_readiness_invariants`
- `self_updating_worker_runtime_foundation_invariants`
- `true_modularity_boundary_invariants`
- `security_authority_capability_boundaries_invariants`
- `public_protocol_api_contract_discipline_invariants`
- `configuration_profile_environment_discipline_invariants` when settings are
  touched
- `data_integrity_storage_evolution_migration_discipline_invariants` when
  storage is touched
- `primitive_code_cleanup_invariants`
- `true_primitive_cleanup_invariants`
- `scripts/personal-info-guard.sh`
- `git diff --check`
- `git ls-files -ci --exclude-standard`
- `test ! -e packages/agent/skills`

Known caveats remain non-goals unless selected by discovery: the pre-existing
DRC UTC allow-list gap in non-selected `goals`, `web`, and `tool_sources`, and
broad pre-existing SOL marker rows outside a touched slice.

## Rejected Shapes

Phase 3 explicitly rejects:

- rebuilding the old modular branch as fixed core domains;
- broad product DTO resurrection;
- fixed native iOS panels before stable module contracts;
- speculative dependency restoration;
- repo-managed first-party skills under `packages/agent/skills`;
- public `/engine` expansion as a substitute for module contracts;
- hidden chain-of-thought exposure or invented reasoning summaries;
- hidden memory or prompt injection;
- live production deployment/update behavior;
- `tron deploy` or production deployment commands.

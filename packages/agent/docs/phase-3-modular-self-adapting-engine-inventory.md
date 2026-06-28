# Phase 3 Modular Self-Adapting Engine Inventory

Status: `complete`

Machine-readable inventory:
[`phase-3-modular-self-adapting-engine-inventory.tsv`](phase-3-modular-self-adapting-engine-inventory.tsv)

This inventory is the durable Phase 3 planning and completion map for restoring
the full modular engine direction. It is grouped by module-plane capability
rather than old fixed product feature. The completed plan uses the old
modular-capability branch as feature evidence while rejecting its fixed-domain
and fixed-panel shape.

## Controlled Vocabulary

Classifications:

- `core_primitive`: engine substrate that every module needs and that remains
  product-neutral.
- `module_plane`: manifest, registry, package lifecycle, validation, install,
  dependency, or runtime infrastructure for modules.
- `module_pack`: a concrete feature family implemented as an installable or
  swappable package.
- `user_control_surface`: iOS or client UI that renders current server/module
  facts and gives the user visibility, approval, or audit controls.
- `deferred`: valid concept that waits for a preceding slice or product
  decision.
- `reject_candidate`: old shape is recorded as evidence but is not restored in
  that form.

Statuses:

- `planned`: accepted in the Phase 3 roadmap, no implementation branch.
- `discovery_ready`: next discovery worker may select the row.
- `pending_review`: implementation candidate exists on a branch but is not
  independently accepted.
- `current_baseline`: accepted and integrated into main.
- `blocked`: discovery or implementation found an external decision or
  prerequisite.
- `rejected_shape`: old behavior is rejected in its old form.

Core involvement values:

- `none`: no engine primitive changes expected.
- `registry`: module registry or manifest source of truth.
- `authority`: grants, selectors, approvals, or policy gates.
- `runtime`: worker/job/sandbox/execution supervisor primitives.
- `storage`: resource/schema/event/store primitives.
- `observability`: activity streams, cockpit projections, and audit surfaces.

Agent self-adaptation values:

- `inspect_only`: agent can inspect the surface but not modify it.
- `proposal`: agent can create a bounded proposal resource.
- `validated_change`: agent can run validation and produce review evidence.
- `installable`: agent can request installation/enablement through approval.
- `active_runtime`: module behavior can run under scoped authority.
- `learned_behavior`: module can encode persistent learned rules/procedures.

## Inventory Summary

The Phase 3 roadmap starts with the module plane before activating feature
packs. This ordering is deliberate:

1. The engine needs a manifest/registry contract before module behavior can be
   installed.
2. The agent needs a safe authoring workspace before self-modification can be
   real.
3. Modules need validation, review, install, enable, disable, quarantine, and
   rollback states before dependencies or execution return.
4. The user needs a generic activity cockpit before old fixed panels are
   reconsidered.
5. Feature packs are activated one at a time after their module ownership,
   authority, dependency, and UI story is proven.

P3MSA-INV-001 is current baseline after accepted Slice 23A: Module Manifest And
Registry Foundation. The accepted slice adds the inspect-only `module_registry`
domain, `module_manifest` resource kind/schema, provider-safe `module_list` and
`module_inspect` execute operation values, explicit read-only
`module_registry.read` plus `resource.read` authority, exact
`kind:module_manifest` and inspect-resource selectors, first-party source-backed
manifest seed records, bounded redacted projections, and no execution or
install side effects. It deliberately does
not install or execute modules, restore dependencies, add repo-managed skills,
expand public `/engine`, add fixed native panels, or introduce a new SQLite
table.

P3MSA-INV-006 is current baseline after accepted Slice 23F: Module Runtime
Execution Supervisor. The accepted slice adds the `module_runtime` domain and
`module_runtime_state` resource kind/schema for enabled-lifecycle-guarded
supervisor envelopes with bounded refs, timeout/cancel/shutdown metadata,
trace-safe request projection, exact runtime/lifecycle selectors, and no raw
commands/logs/output, PTY, browser automation, dependency restore, package
manager, network, direct provider-visible job surface, or physical install
side effects. It moves `P3MSA-INV-006` from `pending_review` to
`current_baseline` after independent re-review acceptance and mainline
integration.

P3MSA-INV-007 is current baseline after accepted Slice 23G: Module Dependency
Request And Policy Activation. The accepted slice adds the `module_dependencies`
domain and generic resource-store-backed `module_dependency_request`,
`module_dependency_decision`, and `module_dependency_policy` resources for
metadata-only dependency governance. The accepted slice keeps provider-visible access
behind `capability::execute` operation values, requires explicit
`module_dependencies.read` / `module_dependencies.write` plus resource
authority, rejects wildcard selectors, requires exact request/decision/policy
selectors for inspect and linked writes, stores owner/module linkage,
dependency identity, rationale, security/license/runtime need, removal plan,
risk class, Cargo.toml/Cargo.lock parity evidence, denial evidence,
idempotency fingerprints, trace/replay refs, bounded refs, side-effect proof,
and `networkPolicy: none`. It deliberately does not run package managers,
restore dependencies, mutate `Cargo.toml` or `Cargo.lock`, install packages,
execute runtime code, access networks, store raw dependency artifacts,
package-manager output, raw local material, raw grant ids, raw authority ids,
token-like strings, or personal-info literals, add public `/engine` APIs, or
add fixed native panels. It moves `P3MSA-INV-007` from `pending_review` to
`current_baseline` after independent review acceptance and mainline integration.

P3MSA-INV-008 is the accepted Slice 23H: Generic Autonomous Work Cockpit
baseline. It adds the `module_activity` domain and system-visible
`module_activity::overview` read projection for trusted engine
clients. It aggregates existing module-plane resources only: manifests,
proposals, validation reports, install requests/decisions, dependency
requests/decisions/policies, lifecycle states, and runtime states. The server
owns truth and redaction, derives active/waiting/blocked/ready/recorded states
only from stored facts, and returns bounded activity summaries, authority
labels, touched-resource summaries, and rollback/quarantine/runtime-
authorization gate status for the existing Runtime Cockpit Activity tab. The
candidate deliberately does not add provider-visible execute operations, public
`/engine` APIs, fixed source-control/memory/process/subagent/notification/skill
panels, client-owned server truth, fake activity, raw payload/log/path/command/
grant/authority/trace/invocation output, install, activation, runtime
execution, dependency restoration, package-manager behavior, or network access.
It moves `P3MSA-INV-008` from `pending_review` to `current_baseline` after
independent re-review acceptance and mainline integration.

P3MSA-INV-009 is accepted baseline after Slice 24A: File And Source-Control
Module Pack Activation. The accepted slice adds a `file_git_module` manifest
seed with manifest lifecycle `pending_review` for the existing filesystem and
Git operation pack, keeps provider-visible access behind the single
`capability::execute` primitive, and maps selected file/Git operations to exact
filesystem, Git, resource, and
trusted-working-directory authority without `agent_state` fallback or wildcard
selectors. The accepted slice declares only existing operation values:
`filesystem_read`, `filesystem_list`, `filesystem_find`,
`filesystem_glob`, `filesystem_search_text`, `filesystem_diff`,
`filesystem_write`, `filesystem_edit`, `filesystem_apply_patch`, `git_status`,
`git_diff`, `git_branch_inventory`, `git_stage`, `git_unstage`, `git_commit`,
and `git_branch_start`. It reuses existing evidence resource kinds:
`patch_proposal`, `materialized_file`, `git_index_change`, `git_commit`, and
`git_branch_start`. Native review UI remains deferred, and broad Git workflows
such as checkout, merge, rebase, reset, stash, fetch, pull, push, PR, and
conflict handling remain rejected until separately selected. It moves
`P3MSA-INV-009` from `pending_review` to `current_baseline` after independent
re-review acceptance and mainline integration.

P3MSA-INV-010 is accepted baseline after Slice 24B: Jobs And Program
Execution Module Pack Activation. The accepted slice adds a pending-review
`jobs_program_execution_module` manifest and a module-owned
`module_program_execution_start/status/cancel/cleanup` path through
`capability::execute`. Start records an enabled-lifecycle-guarded
`module_runtime_state`, writes content-free `program_execution_record`
metadata, delegates the actual non-interactive process to the existing jobs
runtime, then updates module runtime supervision with redacted job/output refs.
Status, cancel, and cleanup require exact module-runtime and job selectors and
return bounded refs, version ids, fingerprints, truncation, duration, exit,
timeout, cancellation, and cleanup metadata only. The candidate deliberately
does not expose `process_run`, `job_start`, `job_log`, raw commands, code,
stdin/stdout/stderr, logs, canonical paths, env values, pids, grant ids, raw
`job_process`/`execution_output` payloads, default network access, package
installs, PTYs, browser automation, fixed cockpit panels, public `/engine`
APIs, production deploy/update behavior, or repo-managed
`packages/agent/skills`. It moves `P3MSA-INV-010` from `pending_review` to
`current_baseline` after independent Fix 2 re-review acceptance and mainline
integration.

P3MSA-INV-011 is accepted baseline after Slice 24C: Subagent Delegation Module
Pack Activation. The accepted slice activates provider-visible
`subagent_launch`, `subagent_status`, `subagent_result`, and `subagent_cancel`
only through the existing `capability::execute` primitive and only by composing
with the accepted jobs/program-execution module pack. Launch records a scoped
`subagent_task` parent lifecycle, requires explicit `modelPolicy:
accepted_jobs_program_execution_v1`, `workerKind: module_program_execution`,
`modulePackId: jobs_program_execution`, bounded objective/prompt summaries,
summary-only handoff refs, exact `resource:<subagent_task_id>` selectors plus
`kind:subagent_task`, exact delegated module lifecycle/runtime/job selectors,
one running task per current scope, and `networkPolicy: none`. Status, result,
and cancel follow the delegated module-runtime/job binding through
`module_program_execution_*`; result returns reviewable merge-proposal evidence
and never mutates parent conversation state. The accepted slice deliberately
does not add hidden autonomous spawning, unbounded context transfer, raw
prompts/results/tool logs, raw command output, local paths, secrets, raw grant
or authority ids, public `/engine` APIs, fixed native subagent panels, package
manager/network side effects, repo-managed `packages/agent/skills`, or
production deploy/update behavior. It moves `P3MSA-INV-011` from
`pending_review` to `current_baseline` after independent Fix 3 re-review
acceptance and mainline integration.

SSARR classification: `self-sufficient-agent-runtime-readiness` treats this
Phase 3 inventory as planning plus accepted module-plane and module-pack
foundation evidence, not successor runtime execution completion proof.

P3MSA-INV-002 remains accepted baseline after Slice 23B: Module Authoring
Workspace Foundation. The accepted slice adds inert `domains/module_authoring`
custody for scoped
`module_proposal` resources using the generic resource store, provider-visible
`module_proposal_record`, `module_proposal_list`, and
`module_proposal_inspect` execute operation values, explicit
module-authoring/resource read-write grants for record, read-only grants for
list/inspect, exact proposal inspect selectors, bounded resource-backed refs,
idempotency fingerprints, lifecycle stream evidence, validation placeholder
status, and explicit no-install/no-execution proof. It does not install or
execute modules, restore dependencies, use package managers, create physical
module workspace directories, touch repo-managed skills, expand public
`/engine`, add fixed native panels, or introduce a new SQLite table. Record,
list, and inspect reject raw payload/code/command/path/prompt fields before
resource handling, and provider-visible title/summary, proposal id, validation
status, and ref metadata reject exact and embedded token-like material before
storage/projection. Rejected module proposal execute payloads are redacted in
provider-visible traces before service validation can fail them.

P3MSA-INV-003 is current baseline after accepted Slice 23C: Module Contract
Test Harness. The accepted slice adds inert
`domains/module_validation` custody for scoped `module_validation_report`
resources using the generic resource store, provider-visible
`module_validation_record`, `module_validation_list`, and
`module_validation_inspect` execute operation values, explicit
module-validation/resource read-write grants for record, read-only grants for
list/inspect, exact validation-report inspect selectors, bounded
module/proposal refs, manifest/resource/provider parity checks, required
docs/tests evidence refs, deterministic command identity/result refs, failure
evidence refs, idempotency fingerprints, lifecycle stream evidence, validation
status/check summaries, and explicit no-install/no-execution proof. It does
not execute commands or module code, restore dependencies, use package
managers, store raw logs/commands/env/code/file contents/unsafe paths, touch
repo-managed skills, expand public `/engine`, add fixed native panels, or
introduce a new SQLite table. Record, list, and inspect reject unsafe payload
fields, unsafe paths, raw shell command-like command/result preview or summary
text, prompt-injection-like strings, credential-like strings, token-like
provider-visible metadata, raw grant ids, raw authority ids, and raw
debug/chain-of-thought material before storage/projection. Re-review accepted
the implementation after the inventory/evidence refresh and raw-shell ref
hardening.

P3MSA-INV-004 is current baseline after accepted Slice 23D: Module Review
Approval And Install Gate. The accepted slice adds inert
`domains/module_install` custody for scoped `module_install_request` and
`module_install_decision` resources using the generic resource store,
provider-visible
`module_install_request_record`, `module_install_request_list`,
`module_install_request_inspect`, `module_install_decision_record`,
`module_install_decision_list`, and `module_install_decision_inspect` execute
operation values, explicit module-install/resource read-write grants for
record, read-only grants for list/inspect, exact request/decision inspect
selectors, validation-report prerequisite revalidation, dependency policy
metadata refs/status, rollback proof refs/readiness, approval freshness checks,
derived-authority proof, denial evidence, idempotency fingerprints, lifecycle
stream evidence, and explicit no-install/no-execution proof. It does not
install or activate modules, restore dependencies, use package managers, execute
code, access networks, touch repo-managed skills, expand public `/engine`, add
fixed native panels, or introduce a new SQLite table. Record, list, and inspect
reject unsafe payload fields, unsafe paths, raw logs/commands/env/code/file
contents, prompt-like/debug material, credential-like strings, token-like
provider-visible metadata, raw grant ids, and raw authority ids before storage
or projection.

P3MSA-INV-005 is the accepted current baseline after Slice 23E: Module Enable
Disable Quarantine And Rollback. The accepted slice adds focused
`domains/module_lifecycle` custody for scoped `module_lifecycle_state`
resources using the generic resource store, provider-visible
`module_lifecycle_request`, `module_lifecycle_decision`,
`module_lifecycle_list`, and `module_lifecycle_inspect` execute operation
values, explicit module-lifecycle/resource grants, exact lifecycle
inspect/decision selectors, current-version lifecycle freshness guards,
current-scope `module_install_decision` prerequisite revalidation, bounded
rollback proof refs/readiness, fresh approval checks, derived-authority proof,
idempotency fingerprints, lifecycle stream evidence, explicit
no-install/no-execution/no-activation proof, and fail-closed disabled/
quarantined runtime authorization metadata. It does not install or activate
modules, restore dependencies, use package managers, execute code, access
networks, touch repo-managed skills, expand public `/engine`, add fixed native
panels, or introduce a new SQLite table. Request, decision, list, and inspect
reject unsafe payload fields, unsafe paths, raw logs/commands/env/code/file
contents, prompt-like/debug material, credential-like strings, token-like
provider-visible metadata, raw grant ids, and raw authority ids before storage
or projection.

## Slice Families

### Module Plane Foundation

Rows P3MSA-INV-001 through P3MSA-INV-008 build the module plane:
manifest/registry, authoring workspace, validation reports, install approval,
activation lifecycle, runtime supervisor, dependency policy, and generic
autonomous-work cockpit.

These rows are prerequisites for broad feature activation. They are not a new
marketplace, not repo-managed skills, and not a public `/engine` expansion.

### Feature Module Packs

Rows P3MSA-INV-009 through P3MSA-INV-016 activate feature families as modules:
file/source-control review, jobs/program execution, subagents, memory
retrieval, procedural learning, web/browser/research, notifications/device
delivery, and import/repository/update workflows.

Each module pack must prove why it belongs outside core, how it obtains
authority, what resources it owns, what dependencies it needs, how it is
validated, how it rolls back, and how the user sees or controls its work.

### Rejected Old Shapes

Rows P3MSA-INV-017 through P3MSA-INV-020 preserve explicit non-goals:
fixed old iOS panels, broad DTO resurrection, speculative dependencies, and
repo-managed skills/bootstrap behavior.

These rows exist so discovery workers do not accidentally reintroduce old
architecture while pursuing the user-facing goal.

## Discovery Rules

Discovery workers must:

- start from clean `origin/main`;
- read this inventory, the TSV row, the Phase 3 scorecard, Phase 2 inventory,
  Phase 1 progress ledger, README, and relevant module `mod.rs` docs;
- restate the product outcome in modular self-adapting-engine terms;
- derive the slice from first principles: agent needs, user control, authority,
  data flow, lifecycle, failure semantics, replay, and redaction before files;
- identify the smallest core primitive, if any;
- identify the module owner, resource owner, authority owner, dependency owner,
  and UI owner;
- identify duplicate, fallback, legacy, dead, or poorly organized code paths in
  the touched area and decide whether the slice removes them now or records a
  precise reason they are outside scope;
- reject broader old shapes explicitly;
- return exact final status `implementation may start` or `blocked`.

## Implementation Rules

Implementation workers must:

- use one focused `codex/phase-3-slice-...` branch;
- keep provider-visible tools bounded to `capability::execute` unless an
  explicit later plan changes that boundary;
- implement the clean minimal contract from first principles rather than
  copying the old modular-capability branch or layering over stale paths;
- keep all new code under clear module ownership, update relevant `mod.rs`
  documentation, split large owners before expanding them, and make file names
  obvious for future discovery;
- remove dead code, obsolete fallback paths, duplicated helpers, stale tests,
  and inaccurate docs that are introduced by or made obsolete by the slice;
- reuse existing authority, resource, event, trace/replay, settings, storage,
  validation, and generic cockpit projection patterns instead of creating
  parallel mechanisms;
- update code, tests, docs, README, and static inventories together when source
  truth changes;
- preserve no-managed-skills under `packages/agent/skills`;
- avoid production deploy/update commands;
- end with exact final status `implementation complete` or `blocked`.

## Accepted Slice 24D

Slice 24D (`P3MSA-INV-012`) is accepted baseline after independent Fix 3
re-review and mainline integration. It keeps memory retrieval, prompt
inclusion, and retention evidence under the existing memory resource contracts
and `capability::execute` audit operations while seeding a pending-review
`memory_engine_module` manifest. The accepted slice records deterministic
resource-backed retrieval over redacted memory record previews, ranked result
refs with confidence/provenance, prompt-inclusion decision proof,
retention/edit/delete policy evidence, exact memory/resource selectors, and
`networkPolicy: none`.

The accepted slice deliberately does not restore embeddings, vector indexes,
generated summaries, automatic retention, fixed native memory panels, public
`/engine` methods, package-manager behavior, or live network behavior. Any
future semantic retrieval engine remains a module/dependency-policy decision.

## Accepted Slice 24E

Slice 24E (`P3MSA-INV-013`) is accepted baseline after independent Fix 1
re-review and mainline integration. It extends the existing
`domains/procedural` owner rather than creating a parallel domain, adds metadata-only
`procedural_record`, `procedural_activation_request`, and
`procedural_activation_decision` resource contracts, and seeds a pending-review
`procedural_module` manifest through the module registry.

The accepted slice records bounded authoring, validation evidence, review
state, trigger declarations, conflict/ordering metadata,
scoped-authority proof, trace/replay refs, bounded refs, idempotency
fingerprints, activation/deactivation/rollback requests, and decision proof
refs behind `capability::execute` operations. Runtime grants and authorization
require exact procedural/resource scopes, exact `kind:*`, `proceduralKind:*`,
and `resource:<id>` selectors, `networkPolicy: none`, and no inherited
`agent_state` for 24E operations.

The accepted slice deliberately does not restore repo-managed
`packages/agent/skills`, copy/bootstrap skills into prompts, register hidden
triggers, inject prompt context, learn behavior automatically, execute generated
or runtime code, restore dependencies, run package managers, access networks,
add SQLite migrations, add public `/engine` methods, or add fixed native UI.

## Accepted Slice 24F: Web Browser And Research Module Pack

Slice 24F (`P3MSA-INV-014`) is accepted baseline after independent Fix 1
re-review and mainline integration. It adds a new `domains/web_research` owner
and a pending-review `web_research_module` manifest seed for metadata-only web
research custody, without mutating the existing `web` source-provenance domain
into a crawler or browser.

The accepted slice records `web_research_request`, `web_research_review`, and
`web_research_source` resources through provider-visible
`capability::execute` record/list/inspect operation values. The records store
bounded summaries, policy labels, source refs, citation refs, robots evidence
refs, dependency-request refs, trace/replay refs, current-scope linkage,
side-effect proof, and idempotency fingerprints only. Runtime grants and
engine authorization require exact `web_research.read` /
`web_research.write` plus resource scopes, exact `kind:web_research_*`
selectors, exact `resource:<id>` selectors for inspect and linked review/source
writes, and `networkPolicy: none`.

The accepted slice deliberately does not add search provider integration, crawling,
sitemap traversal, browser automation, login/cookie reuse, raw HTML/page dumps,
raw browser logs, package-manager or dependency restoration behavior,
network-enabled runtime defaults, public `/engine` expansion, fixed native UI,
repo-managed `packages/agent/skills`, or production deploy/update behavior.

## Accepted Slice 24G: Notifications And Device Delivery Module Pack

Slice 24G (`P3MSA-INV-015`) is accepted baseline after independent Fix 2
re-review. It adds a pending-review `notification_delivery_module` manifest
seed for the existing server-owned `domains/device` and `domains/notifications`
substrate. The manifest covers only existing `device_registration`,
`notification`, and `notification_delivery` resources and existing
`capability::execute` operation values for device list/inspect/register/
unregister and notification send/list/inspect/mark-read/mark-all-read.

The accepted slice preserves the trusted system/admin split for
`device_register` and `device_unregister`, declares device, notification, and
resource authority needs bounded to the existing resource kinds with
`kind:device_registration`, `kind:notification`, and
`kind:notification_delivery` selectors, and keeps `networkPolicy: none`,
`installable: false`, `executable: false`, and manifest lifecycle
`pending_review`. Validation checks remain gates for APNs credential
custody, APNs environment labels, entitlement proof, physical-device
validation, delivery-failure evidence, provider redaction, and native inbox
product decisions.

The accepted slice deliberately does not add live APNs transport, native inbox UI,
APNs entitlements, physical-device operations, credential mutation, package
manager execution, network side effects, SQLite migrations, public
notification APIs, fixed native panels, repo-managed `packages/agent/skills`,
or production deploy/update behavior. Provider-visible projections remain
bounded and omit raw APNs tokens, raw device tokens, credentials, device
secrets, raw provider payloads, full token hashes, grants, authority ids, and
local material.

## Accepted Slice 24H: Import Repository And Update Module Pack

Slice 24H (`P3MSA-INV-016`) is accepted baseline after independent Fix 1
re-review. It adds a pending-review `import_update_module` manifest seed for the
existing `domains/import_history`, `domains/repository_tree`,
`domains/import_preview`, and `domains/update_diagnostics` metadata
foundations. The manifest covers only existing `import_history_*`,
`repository_tree_*`, `import_preview_*`, and `update_diagnostic_*`
`capability::execute` operation values and their existing durable resource
kinds.

The accepted slice declares `import_history_record`, `repository_tree_snapshot`,
`import_preview`, and `update_diagnostic_record` resource declarations with
domain-owned payload schema versions, kind-selector-bounded domain and generic
resource authority metadata, `networkPolicy: none`, `installable: false`,
`executable: false`, and manifest lifecycle `pending_review`. Validation
checks remain gates for approval, rollback, future action contracts, bounded
payload custody, and provider redaction.

The accepted slice deliberately does not add import execution, repository mutation,
raw repository tree dumps, raw diagnostics payloads, live update checks,
installer/restart/update commands, package-manager behavior, production deploy
behavior, SQLite migrations, public `/engine` expansion, native fixed panels,
repo-managed `packages/agent/skills`, or network behavior. Provider-visible
projections remain bounded and omit raw import payloads, raw repository
contents, file contents, unsafe paths, endpoints, commands, packages, grants,
authority ids, and token-like material.

## Accepted Rejected Shape Slice 24I: Fixed Old iOS Product Panels

Slice 24I (`P3MSA-INV-017`) is accepted rejected-shape baseline after
independent review and mainline integration. It keeps the user-control surface
rule unchanged: the generic Runtime Cockpit renders server-owned module facts
first, and workflow-specific native panels require stable module contracts plus
a product decision that generic rendering is insufficient.

The accepted slice records explicit absence of old fixed source-control, memory,
process, approval, work, subagent, notification, and skill panels. The iOS
source guard now names approval and work panel sentinels directly, including
old work dashboard wording, while preserving the existing fabricated-activity
and other fixed-panel checks.

The rejected shape remains forbidden: no approval panel, work panel, work
dashboard, process panel, source-control panel, subagent panel, notification
panel, skill panel, memory panel, fake local inbox/activity/source surface,
client-owned server truth, public `/engine` expansion, broad DTO resurrection,
package-manager/network behavior, physical-device work, SQLite migration, or
repo-managed `packages/agent/skills` belongs to this slice.

## Accepted Rejected Shape Slice 24J: Broad Product DTO Resurrection

Slice 24J (`P3MSA-INV-018`) is accepted rejected-shape containment after
independent review and mainline integration. It keeps DTO/protocol growth tied
to accepted module resources and stable workflows instead of reviving the old
product DTO layer as a compatibility bucket.

Accepted surfaces stay narrow and module-owned: `module_activity::overview`
and its iOS module activity DTOs, generic worker lifecycle resource DTOs,
accepted resource kinds including `ui_surface`, and generated UI DTOs used by
`GeneratedRuntimeSurfaceView`. These surfaces decode unknown server fields for
forward compatibility, but unknown product-shaped fields are not preserved as
client-owned fallback state.

The accepted slice adds static iOS source guards against broad product DTO
namespaces, old product protocol files/directories, product event payload files,
public protocol product clients, and product table names. It also reinforces
that the event catalog remains the primitive loop catalog in
`packages/agent/src/domains/session/event_store/types/generated.rs`; product
event variants are not part of this slice.

The rejected shape remains forbidden: no broad product DTO buckets, product
tables, product-specific event catalog variants, fixed panels, public `/engine`
expansion, fallback/shim decoding path, client-owned truth, SQLite migration,
package-manager/network behavior, production deploy/update behavior, or
repo-managed `packages/agent/skills` belongs to this slice.

## Accepted Rejected Shape Slice 24K: Speculative Dependency Restoration

Slice 24K (`P3MSA-INV-019`) is accepted rejected-shape containment after
independent review and mainline integration. It keeps removed dependencies
absent unless a selected module owns the request and the accepted
`P3MSA-INV-007` dependency governance path approves it.

The accepted slice strengthens the primitive cleanup dependency guard so the
removed dependency catalog remains source-backed by the feature index and
accepted Phase 2 Slice 22A evidence, while Phase 3 reappearance requires an
approved `module_dependency_request`, approved `module_dependency_policy`,
module owner rationale, risk class, tests, removal path, and `Cargo.toml` /
`Cargo.lock` parity evidence. The guard denies direct manifest or lockfile
reappearance of removed dependency names without that approved module
rationale.

The rejected shape remains forbidden: no speculative dependency restoration,
no runtime dependency restoration, no `portable-pty`, interpreter,
embedding/vector, browser automation, APNs transport, signing, or rendering
package return, no package-manager execution, no manifest or lockfile
mutation, no network install, no raw dependency artifacts, no package-manager
output, no public `/engine` expansion, no fixed native panel, no repo-managed
`packages/agent/skills`, no production deploy/update behavior, and no dependencies are restored.

## Accepted Rejected Shape Slice 24L: Repo-Managed Skills And Bootstrap Behavior

Accepted Slice 24L (`P3MSA-INV-020`) is current-baseline rejected-shape
containment. It keeps procedural behavior framed as agent-authored,
module-owned, resource-backed state rather than core repo-managed skills or
bootstrap prompt context.

The accepted implementation strengthens static guards across tracked agent
sources so no `packages/agent/skills` directory, package `SKILL.md` assets,
repo-managed first-party skill assets, skill-copy wiring, bootstrap skill
registries, bootstrap prompt context, or hidden prompt-context skill injection
can return unnoticed. It also records the accepted exception clearly:
`module_registry_procedural_manifest` may seed a source-backed
`procedural_module` manifest only as metadata-only registry evidence tied to
accepted `P3MSA-INV-013`; it is not a skill asset, package install, prompt
context plane, or runtime behavior.

The rejected shape remains forbidden: no repo-managed first-party skills, no
package `SKILL.md` assets under `packages/agent`, no skill-copy/sync/load
wiring, no bootstrap skill registry, no hidden prompt injection, no
auto-activated learned behavior, no generated/runtime code execution, no
package-manager or network behavior, no public `/engine` expansion, no fixed
native skill panels, and no production deploy/update behavior belongs to this
slice.

## Review Rules

Review workers must:

- compare `baseline..head`;
- verify branch/head/cleanliness/ancestry;
- inspect code/tests/docs/evidence;
- verify the slice stays modular and minimal;
- verify the implementation is agent-first, user-governed, first-principles,
  organized, deduplicated, and free of new legacy/fallback/dead paths;
- run focused validation;
- return exact verdict `slice accepted` or `changes required`.

Focused fix workers address only review findings, add deterministic regression
coverage, and return `fix ready for review` or `blocked`. Re-review repeats
until accepted or blocked.

## Deferred Decision Register

These decisions remain explicit product/architecture decisions, not accidental
implementation details:

- whether any native fixed workflow panel is justified after generic cockpit
  rendering;
- which dependencies a specific module can restore;
- whether live APNs delivery is enabled;
- which program runtimes are allowed;
- whether PTY is allowed;
- whether browser automation can use cookies or logged-in sessions;
- how memory retrieval and prompt inclusion are governed;
- what learned procedural behavior may activate automatically;
- how subagent result merge is reviewed;
- whether production update checks or installers are ever in scope.

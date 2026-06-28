# Phase 3 Modular Self-Adapting Engine Inventory

Status: `planned`

Machine-readable inventory:
[`phase-3-modular-self-adapting-engine-inventory.tsv`](phase-3-modular-self-adapting-engine-inventory.tsv)

This inventory is the durable Phase 3 planning map for restoring the full
modular engine direction. It is grouped by module-plane capability rather than
old fixed product feature. The plan uses the old modular-capability branch as
feature evidence while rejecting its fixed-domain and fixed-panel shape.

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

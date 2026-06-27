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
manifest seed records, and bounded redacted projections. It deliberately does
not install or execute modules, restore dependencies, add repo-managed skills,
expand public `/engine`, add fixed native panels, or introduce a new SQLite
table.

SSARR classification: `self-sufficient-agent-runtime-readiness` treats this
Phase 3 inventory as planning plus accepted inspect-only module-registry
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

P3MSA-INV-005 is pending review after Slice 23E implementation-candidate:
Module Enable Disable Quarantine And Rollback. The candidate adds focused
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

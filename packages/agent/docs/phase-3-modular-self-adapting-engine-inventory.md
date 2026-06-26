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

P3MSA-INV-001 has an implementation candidate on branch
`codex/phase-3-slice-23a-module-manifest-registry` and is marked
`pending_review` in the TSV. It is not `current_baseline` until independent
review accepts and integrates it.

SSARR classification: `self-sufficient-agent-runtime-readiness` treats this
Phase 3 inventory as planning and review-candidate evidence, not successor
runtime completion proof.

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

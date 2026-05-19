# Modular Engine Cleanup Audit

Last verified: 2026-05-19 on `next/modular-capability-engine`.

This document is the proof map for the cleanup pass that follows the generated
UI substrate checkpoint. The rule for this pass is remove with proof: code is
kept only when it has a current substrate role, reusable capability contract,
runtime caller, thin-client purpose, or test/support role.

## Current Substrate Map

| Area | Classification | Evidence | Decision |
|------|----------------|----------|----------|
| `app`, `transport`, `shared`, `platform` | distribution/support | `src/lib.rs`, README module map, startup and protocol entrypoints | Keep; only remove stale product routes when exact callers are gone |
| `engine` fabric | substrate | 38 Rust files under `packages/agent/src/engine`; primitive workers register catalog, control, grant, resource, storage, UI, worker, queue, stream, state, approval, observability | Keep; consolidate projection logic into owning primitives |
| `engine/primitives/control.rs` | substrate thin projection | public `control::snapshot` and `control::inspect`; static gate forbids `control::act` | Keep; owns control projection shaping and action summaries |
| `engine/primitives/runtime.rs` | runtime dispatch | host-dispatched primitive boundary and host trait | Keep; should dispatch to primitive owners, not accumulate projection code |
| `engine/resources.rs` | substrate resource kernel | built-in resource definitions, validation, resource/version/link stores, UI-surface validation | Keep for now; candidate for later file split after behavior is stable |
| Domain registration | capability modules | 36 domain contract files and 32 startup worker-module registrations in `domains/registration.rs` | Keep as current capability surface until each domain is individually proven unused or duplicated |
| `cron` server domain and iOS DTO/client | capability module | `cron::` contracts, `CronClient`, DTO tests | Keep as reusable capability module; remove fixed iOS dashboard shell |
| `voice_notes` server domain and recording components | capability module / chat affordance | `voice_notes::` contracts and chat recording sheet/button still have callers | Keep; remove fixed iOS list shell |
| iOS chat/session surfaces | thin shell | `ContentView`, `SessionSidebar`, `ChatView`, onboarding/settings pairing paths | Keep as thin chat harness until replaced by generated surfaces |
| iOS Engine Console | thin control client | `NavigationMode.engine`, `EngineConsoleState`, `control::*` DTOs, generated UI renderer | Keep; no local policy truth |
| Fixed iOS Automations dashboard | remove candidate | only reached through `NavigationMode.automations`; duplicates future control/generated UI surface for cron | Remove from top-level navigation and delete fixed views |
| Fixed iOS Voice Notes list | remove candidate | only reached through `NavigationMode.voiceNotes`; voice recording remains callable from chat | Remove from top-level navigation and delete fixed list |
| `SafariView` browser wrapper | remove candidate | no production caller; only self-preview reference | Remove |

## Cleanup Decisions Applied

- Moved control snapshot/inspect projection construction out of the generic
  primitive runtime and into `engine/primitives/control.rs`. Runtime now dispatches
  to the control primitive; the control primitive owns substrate action summaries,
  UI-surface refs, and target graph shaping.
- Removed control `payloadTemplate` summaries. Control projections now expose
  action identity, target type/field, risk, approval, revision, and target value
  hints only. Executable generated-UI payload templates remain stored and
  validated only on `ui_surface` resources.
- Removed the fixed iOS Automations dashboard files. Cron DTOs/client/tests remain
  because cron is a reusable capability module; the bespoke dashboard was product
  shell state.
- Removed the fixed iOS Voice Notes list and `voice-notes` deep-link route. Chat
  voice recording remains as an explicit chat affordance.
- Removed the unused `SafariView` wrapper. Browser capability/event DTOs remain
  until the browser/display capability family is audited end-to-end.
- Split the generated-UI engine tests into `engine/tests/generated_ui.rs` as the
  first test-module boundary around the previously monolithic engine test file.

## 2026-05-19 Trust Review Cleanup Pass

The package trust review and scheduled-audit phase was audited before the next
feature phase. No new package, trust, audit, schedule, or policy table was
justified; the added behavior remains represented as `decision` and `evidence`
resources plus queue projections.

| Area | Evidence | Decision |
|------|----------|----------|
| Trust-review capabilities | Registered as `module::*` functions with tests in `engine/tests/module_activation/trust_review.rs` and static gates in `tests/threat_model_invariants.rs` | Keep; they are canonical module capabilities over resource/decision/evidence truth |
| Scheduled audit due calculation | `EngineHostHandle::enqueue_due_module_trust_audits` scans active `module_trust_audit_schedule` decision resources and enqueues deterministic module queue work | Keep as projection; no scheduler table or automation plane |
| Duplicate schedule parsers | The module primitive and host had separate wall-clock/day parsing after the scheduled-audit phase | Consolidated into module-owned helpers used by both schedule validation and host queue projection |
| Trust operation enum strings | Operation lists were duplicated between module validation/schema and generated UI input schemas | Consolidated into `TRUST_REVIEW_OPERATIONS`; UI now builds operation inputs from the same source |
| Trust-review tests | Recent tests made `engine/tests/module_activation.rs` carry schedule/simulation/review concerns directly | Split into `engine/tests/module_activation/trust_review.rs`; shared fixtures remain in the parent module |
| Bounded evidence string truncation | Byte-count `String::truncate` could panic on a multibyte UTF-8 boundary for operator notes or bounded JSON previews | Replaced with char-boundary-safe truncation and added multibyte operator-note coverage |

Removal proof from this pass:

- No safe public capability removal was found in the recent trust-review work:
  all four new functions have registration, generated UI/control action
  exposure, focused tests, and static gates.
- No iOS cleanup was required: no Swift files reference the new trust-review
  function ids, and existing generated UI rendering remains the thin action
  submission path.
- No storage reset was justified: schemas did not add tables and remain within
  the existing resource/decision/evidence substrate.

## 2026-05-19 Maturity Scorecard And Module Split

The first maturity checkpoint added a measurable scorecard and applied the
lowest-risk production-code split around recent trust-review work.

| Area | Evidence | Decision |
|------|----------|----------|
| Maturity tracking | `docs/modular-engine-maturity-scorecard.md` defines an 8-axis 100-point rubric with current scores, evidence, blockers, and next actions | Keep as the durable definition of progress toward the 100% end state |
| Scorecard gates | `tests/threat_model_invariants.rs` verifies the scorecard exists, contains all axes, totals 100 points, and preserves collapsed-substrate/forbidden-path rules | Keep in static gates so maturity tracking cannot drift into aspirational docs |
| Trust review implementation ownership | `engine/primitives/module/trust_review.rs` owns simulation, review evidence, operation constants, schemas, and recommended review actions | Consolidated from the parent module file without changing public function ids or wire shape |
| Scheduled trust audit implementation ownership | `engine/primitives/module/trust_audit.rs` owns schedule creation, due-run evidence, schedule parsing, schedule ids, and audit schemas | Consolidated from the parent module file; host remains a queue projection only |
| Parent module primitive | `engine/primitives/module.rs` still owns registration, dispatch, lifecycle, package source/trust, activation, health, integrity, and shared helpers | Keep for now; future splits should target source/signature and activation/health once behavior is stable |

Removal proof from this pass:

- No runtime capability or public response shape was removed; this checkpoint is
  organization plus measurement only.
- No iOS changes were needed because generated UI action submission remains
  server-authored and dynamic.
- No storage change was justified; the scorecard explicitly forbids adding
  package/source/policy/trust/audit tables.

## 2026-05-19 Trust Audit Reliability Pass

Scheduled module trust audits were hardened without adding a scheduler, audit
table, policy table, status cache, or iOS policy layer.

| Area | Evidence | Decision |
|------|----------|----------|
| Trust audit status | `module::trust_audit_status` projects due buckets, queued/completed buckets, missed windows, latest evidence, affected refs, and retention warnings from existing decisions/evidence/queue/resources | Keep as pure read projection; no durable status cache |
| Trust audit retention | `module::record_trust_audit_retention` writes bounded `evidence` with eligible audit evidence refs and links back to the schedule/old evidence | Keep as advisory evidence only; no deletion or archive mutation |
| Due-bucket ownership | Host queue projection calls module-owned due-bucket and completed-evidence helpers | Keep; host remains a queue projection and no longer owns schedule parsing logic |
| Schedule expiry | `module::expire_trust_decision` accepts `module_trust_audit_schedule` decisions through the same CAS/evidence path as other trust decisions | Keep; no schedule-specific mutation multiplexer |
| Generated operator actions | Control and generated UI expose schedule status, run, retention review, and expiry through canonical stored actions | Keep; no `control::act` or client-authored payload path |

Removal proof from this pass:

- No new public scheduler/status/table API was justified; status is rebuilt
  from substrate truth.
- Missed audit windows are surfaced as facts and are not backfilled
  automatically.
- Retention review does not delete bytes, rewrite resource versions, stop
  workers, revoke grants, or mutate schedules.

## 2026-05-19 Activation Runtime Cleanup Pass

Local-process activation cleanup was hardened without adding a health table,
cleanup table, status cache, alternate worker-spawn path, or iOS policy layer.

| Area | Evidence | Decision |
|------|----------|----------|
| Post-spawn cleanup | `module::activate` records `module_activation_runtime_diagnostic` evidence and revokes/stops spawned runtime state when registration, validation, or persistence fails | Keep as module-owned evidence over existing resources/grants/workers |
| Missing registration | Worker-spawn results that return a grant but never register the worker revoke the derived grant before returning | Keep; no active grant may survive a missing worker registration |
| Manual recovery | `module::recover_activation` records `manual_recovery_required` when grant or worker cleanup fails | Keep; recovery must surface uncertainty instead of fabricating success |
| Operator projection | `module::inspect_package` reports cleanup/recovery status, leaked grant refs, leaked worker refs, latest recovery evidence refs, and canonical next actions | Keep as projection-only diagnostics; no status table |
| Static gates | Threat-model gates require the activation runtime diagnostic path and continue forbidding direct process spawn/kill, module action multiplexers, and health/cleanup tables | Keep as absence proof |

Removal proof from this pass:

- No new public runtime-status capability was justified; existing package
  inspection and control/generated UI projections carry diagnostics.
- No new durable state was justified; cleanup facts are `evidence` resources and
  activation record versions.
- No client policy or generated UI mutation shortcut was justified; recovery,
  disable, quarantine, health, and integrity remain canonical capabilities.

## 2026-05-19 Activation Runtime Ownership And Stress Soak Pass

Activation runtime cleanup was moved out of the parent module primitive and
stress-tested through queue retry plus real local-process cycles without
changing public capability ids, schemas, storage generation, generated UI
actions, or iOS behavior.

| Area | Evidence | Decision |
|------|----------|----------|
| Runtime helper ownership | `engine/primitives/module/activation_runtime.rs` owns local-process spawn composition, command resolution, volatile worker cleanup, spawned-worker stop, runtime failure evidence, partial activation recovery, invocation-family lookup, and runtime diagnostic projection helpers | Keep as focused module submodule; parent `module.rs` remains lifecycle dispatch/orchestration |
| Static ownership proof | `threat_model_invariants::module_package_activation_gates_stay_on` requires `mod activation_runtime;` and rejects runtime helper implementations drifting back into `module.rs` | Keep as structural gate rather than a brittle line-count rule |
| Queue retry proof | `module_queued_activation_retry_does_not_duplicate_runtime_state` uses a fail-once `worker::spawn` fixture and existing queue backoff to prove retry success creates one activation version, one active derived grant, one live worker, and a completed queue item | Keep; queue retries use attempt-scoped target idempotency after a failed attempt so a stored handler failure does not become retry acceptance state |
| Real local-process soak | `e2e_local_process_module_activation_health_and_disable_use_real_worker_spawn` now runs two activate -> health -> disable cycles through real `worker::spawn` and `sandbox::stop_spawned_worker` | Keep as bounded e2e proof of no volatile worker or active activation grant leakage after repeated cycles |

Removal proof from this pass:

- No new runtime-status capability was justified; runtime diagnostics remain
  package/control/generated-UI projections over existing activation/evidence/
  grant/worker records.
- No new queue, retry, health, cleanup, or status table was justified.
- No alternate module process spawn/kill path was justified; local-process
  packages still compose canonical `worker::spawn` and
  `sandbox::stop_spawned_worker`.

## 2026-05-19 Resource Kernel And Generated UI Boundary Pass

The resource kernel and generated-UI validation boundary were split without
changing public capability ids, request/response schemas, resource kinds,
storage generation, generated UI catalog behavior, or iOS surfaces.

| Area | Evidence | Decision |
|------|----------|----------|
| Resource facade | `engine/resources/mod.rs` now contains only ownership docs, submodule declarations, and stable re-exports for `builtin_resource_type_definitions`, store types, public resource types, `ui_component_catalog`, and `validate_ui_surface_payload` | Keep as the stable import surface |
| Public resource types | `engine/resources/types.rs` owns resource structs, enums, constants, and parse/string helpers needed by the store | Keep; no persistence or UI payload validation belongs here |
| Built-in resource definitions | `engine/resources/definitions.rs` owns built-in resource type registration, schemas, lifecycle states, and link relations | Keep; static gates prevent definitions from drifting into the store |
| Generic resource validation | `engine/resources/validation.rs` owns request validation, lifecycle/relation checks, schema validation, and dispatch to UI-surface payload validation | Keep; no table creation or persistence logic belongs here |
| Version helpers | `engine/resources/versions.rs` owns payload hashing | Keep as the current small hash boundary; expand only when more version/integrity helpers stabilize |
| UI-surface payload validation | `engine/resources/ui_surface.rs` owns the fixed catalog, component catalog, payload bounds, component/action payload validation, placeholder checks, and secret/local-file content rejection | Keep; this remains resource validation, not a generated-UI runtime action path |
| Resource stores | `engine/resources/store.rs` owns in-memory and SQLite resource store implementations, row mapping, store events, and store unit tests | Keep; no built-in type definitions or UI-surface validation should live here |
| Generated UI action validation | `engine/primitives/ui/validation.rs` owns stored-surface diagnostics, stale/expired/damaged checks, action-target validation, template checks, and `ui::submit_action` child invocation construction | Keep; parent `ui.rs` remains registration, dispatch, and authoring coordination |
| Resource tests | `engine/tests/resource_kernel.rs` now owns resource/materialization characterization that had been embedded in the monolithic engine test file | Keep as the focused test module for resource-kernel behavior |
| Static gates | `threat_model_invariants::resource_kernel_and_generated_ui_ownership_boundaries_stay_split` verifies the ownership split and forbids resource/control/UI tables, dynamic catalogs, fallback renderers, compatibility aliases, and client-authored target override paths | Keep as ownership proof |

Removal proof from this pass:

- No public resource import was removed; callers continue to import through
  `crate::engine::resources`.
- No serialized resource, generated UI, or capability shape was changed.
- No new state plane was justified; all changes were file ownership, tests, and
  documentation.
- No iOS change was justified because the server-side DTO and generated UI
  catalog remained stable.

## Deferred High-Scrutiny Areas

These areas are not proven removable in this checkpoint and need separate
call-graph/test-backed passes:

- `notifications`: still drives APNs, notification inbox, and engine-delivered
  operator notices. Remove only after notification delivery is replaced by
  resource/control projections or a generated surface.
- `prompt_library`: still has settings, input-bar, history, and snippet callers.
  It should become artifact/resource-backed before any deeper deletion.
- `AgentControl`, `SourceChanges`, and subagent sheets: still have chat-sheet
  callers and event-state dependencies. Replace with resource lineage/control
  projections before deletion.
- `browser`, `display`, `device`, `transcription`, and `voice_notes` server
  domains: still register capability workers and may support chat or local device
  flows. Demote or remove only with route, DTO, and event-plugin proof.
- `engine/resources.rs` and the remaining `engine/tests.rs` body: large files
  that need further mechanical splitting, but no behavior should move until the
  current cleanup tests pass.

## Static Gates

The cleanup is protected by static tests that require:

- no `control::act`;
- no output-audit acceptance path;
- no public `sandbox::spawn_worker` path;
- no notification markdown blob as durable subagent result path;
- no iOS-generated UI action submission fields that let the client choose target
  function, payload template, or grant;
- no fixed iOS Automations/Voice Notes dashboard names or retired navigation
  cases;
- no local iOS generated-UI fallback renderer.

## Verification Targets

- Rust targeted static gates: `cargo test --test threat_model_invariants`.
- Rust broad check for engine refactors: `scripts/tron ci fmt check clippy test`.
- iOS project refresh after deleting source files:
  `cd packages/ios-app && xcodegen generate`.
- iOS targeted tests: navigation, source guards, generated UI DTO/cache, and
  Engine Console state tests.
- Final hygiene: `git diff --check` and README/doc scans for removed names.

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
| `engine/resources/` | substrate resource kernel | focused modules for built-in resource definitions, validation, resource/version/link stores, and UI-surface validation | Keep; resource ownership split is complete |
| Domain registration | capability modules | 36 domain contract files and 32 startup worker-module registrations in `domains/registration.rs` | Keep as current capability surface until each domain is individually proven unused or duplicated |
| `cron` server domain and iOS DTO/client | capability module | `cron::` contracts, `CronClient`, DTO tests | Keep as reusable capability module; remove fixed iOS dashboard shell |
| `voice_notes` server domain and recording components | resource-backed capability module / chat affordance | `voice_notes::save/list/delete` contracts and chat recording sheet/button still have callers; durable notes are `artifact`/`materialized_file` resources | Keep; no file-backed list/delete truth |
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

## 2026-05-19 Engine Test Ownership Split

The remaining central `engine/tests.rs` body was replaced by an owned
`engine/tests/` module tree. This was a behavior-preserving test organization
change only: public capability ids, schemas, storage, runtime behavior, and
client surfaces did not change.

| Area | Evidence | Decision |
|------|----------|----------|
| Test root | `engine/tests/mod.rs` contains ownership docs, module declarations, and a shared fixture export; static gates forbid test bodies there | Keep as declaration-only test map |
| Shared fixtures | `engine/tests/support.rs` owns reusable IDs, handlers, causal contexts, resource/ledger helpers, and external-worker test imports | Keep; promote shared setup here only when multiple concern files need it |
| Concern-owned tests | `ids_types`, `catalog_discovery`, `ledger_idempotency`, `host_invocation`, `meta_primitives`, `triggers`, `streams`, `state_queue`, `leases_compensation`, `approval`, and `external_worker` own the moved central tests | Keep; new engine tests must land in an owning concern file |
| Existing focused tests | `generated_ui`, `grant_authority`, `module_activation`, `resource_kernel`, `domain_outputs`, and `prompt_library_resources` remain focused proof boundaries | Keep; no consolidation back into a catch-all file |
| Coverage proof | The old central 100 test names were compared against the split tree with no missing tests and no duplicate names across engine tests | Keep as checkpoint evidence; future coverage is protected by focused filters and static gates |

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

## 2026-05-19 Module Primitive Ownership Split

The source-trust and health/integrity paths were extracted from the parent
module primitive without changing public function ids, schemas, output
contracts, generated UI actions, resource kinds, storage generation, or iOS
surfaces.

| Area | Evidence | Decision |
|------|----------|----------|
| Source-trust ownership | `engine/primitives/module/source_trust.rs` owns source registration, source verification, Ed25519 signature verification, source approvals/revocations, policy decisions, policy audits, trust inspection, renewal, rotation, expiry, reconciliation, and revocation enforcement | Keep as the single module trust/policy implementation boundary |
| Health/integrity ownership | `engine/primitives/module/health_integrity.rs` owns health checks, integrity verification, conformance evidence, activation recovery entrypoint logic, and health/integrity schemas | Keep separate from activation runtime cleanup so recovery can compose canonical grant/worker cleanup without reimplementing it |
| Parent module role | `engine/primitives/module.rs` now remains package lifecycle registration, dispatch, activation orchestration, and shared substrate helper glue | Keep narrow; do not move policy behavior back into the parent coordinator |
| Test ownership | `engine/tests/module_activation/source_trust.rs` and `engine/tests/module_activation/health_integrity.rs` hold the moved concern tests with shared fixtures in the parent module activation test file | Keep tests organized by substrate concern instead of one monolithic activation file |
| Static gates | `tests/threat_model_invariants.rs` requires `mod source_trust`, `mod health_integrity`, moved helper ownership, split tests, and the existing forbidden-path rules | Keep as absence proof against helper drift, parallel state planes, direct process spawn/kill, and local iOS policy |

Removal proof from this pass:

- No compatibility alias, fallback route, table, storage reset, or public DTO
  reader was added.
- No source-trust or health/integrity implementation body remains in the parent
  module primitive.
- Shared helpers remain in the parent only when they are used by multiple module
  submodules.

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

## 2026-05-19 Grant, Manifest, Resource Ref, And UI Action Hardening Pass

This pass added proof-depth hardening without changing public capability ids,
wire schemas, storage generation, resource kinds, generated UI catalogs, iOS
surfaces, or package/runtime state planes.

| Area | Evidence | Decision |
|------|----------|----------|
| Grant authority | `engine/tests/grant_authority.rs` now owns grant-narrowing and rejected-prepare tests for capabilities, namespaces, authority labels, resource kinds/selectors, file roots, network policy, risk, budget, expiry, approval, missing grants, revoked grants, expired grants, subject mismatches, selector mismatches, file-root escapes, exhausted budgets, and raw-scope non-authority | Keep as the focused grant proof boundary |
| Package manifest validation | `module_register_package_rejects_adversarial_manifest_shapes_without_persistence` covers duplicate function ids, raw secret-like values, unsafe local-process command refs, and unsupported local-process visibility | Keep manifest hardening in module activation/source-trust tests because package trust policy consumes the same manifest shape |
| Manifest parser | `declared_capabilities` now rejects duplicate `functionId` entries before package resource persistence | Keep as a root-cause validation fix, not a compatibility layer |
| Resource output refs | `resource_backed_invocation_rejects_malformed_or_wrong_kind_refs_without_persisting_refs` covers wrong resource kind, missing role, invalid version/hash fields, non-object refs, and failed produced-ref persistence | Keep in the resource-kernel test boundary |
| Generated UI actions | `ui_submit_action_rejects_invalid_input_and_stale_target_before_child_invocation` proves invalid stored-action input and stale target revisions fail before child invocation | Keep in generated UI tests; iOS remains a thin submitter |
| Static gates | `grant_manifest_resource_and_ui_hardening_tests_stay_in_owning_boundaries` requires these proof cases to remain in the owning test modules | Keep as ownership proof |

Removal/consolidation proof from this pass:

- No new table, cache, compatibility reader, fallback manifest field, dynamic UI
  catalog, control action multiplexer, or worker-spawn path was introduced.
- No iOS DTO or surface change was justified because server wire shapes were
  unchanged.
- The only production behavior change is stricter manifest validation for
  duplicate declared function ids, which fails before persistence.

## 2026-05-19 Operator Consequence And Voice-Notes Resource Conversion Pass

This pass closed one deferred durable-output domain and added consequence
projections without adding a control-plane state model.

| Area | Evidence | Decision |
|------|----------|----------|
| Operator action summaries | `engine/primitives/action_summary.rs` is used by control projections, module package/trust actions, trust-audit status, and generated UI action authoring | Keep one helper so action state, risk, approval, target revision, supporting refs, and recommended canonical action do not drift by surface |
| Generated UI stored actions | `generated_ui` tests now assert stored actions carry consequence projections and still target canonical capabilities only | Keep as projection data; `ui::submit_action` remains the only generated-UI action gateway |
| Module/package/trust projections | Module activation and trust-audit tests assert `module::inspect_package` and `module::trust_audit_status` expose consequence-bearing available actions | Keep read-only projection shape; do not add `control::act` or action multiplexers |
| `voice_notes::save` | `engine/tests/domain_outputs.rs` proves save returns `artifact` and `materialized_file` `resourceRefs`, duplicate idempotency does not duplicate resources, and invalid audio records no accepted produced refs | Convert durable note output to resources; Markdown file path is materialized location only |
| `voice_notes::list` | The same tests create an unrelated Markdown file and prove list returns only resource-backed notes | Keep old unregistered files ignored; no compatibility reader or migration path |
| `voice_notes::delete` | Tests prove delete discards resource lifecycle and does not depend on physical file deletion | Keep byte cleanup deferred to resource retention/storage policy |
| Static gates | `operator_consequence_and_voice_note_resource_boundaries_stay_enforced` requires the action-summary helper, resource-backed voice-note contracts, focused domain-output tests, and no direct `std::fs::write/read_dir/remove_file` durable path in the voice-notes domain | Keep as absence proof against reintroducing file-backed truth |

Deferred domain-output proof map:

| Domain/surface | Current evidence | Decision |
|----------------|------------------|----------|
| `notifications` | `notifications::send/list/mark_read/mark_all_read` still drive APNs, notification inbox, and iOS notification views | Defer; convert inbox state to resources only after delivery semantics and APNs operator UX are specified |
| `prompt_library` | Server resource-backed artifacts plus iOS input-bar/history/snippet callers remain active | Converted durable state; keep the iOS sheet as a thin capability client |
| AgentControl/source-change/subagent sheets | iOS chat sheets and event-state dependencies remain active | Defer; replace with resource lineage/control/generated UI before deleting fixed sheets |
| `browser`, `display`, `device` | Server domains still register workers and support local device/display flows; iOS display stream DTOs remain active | Keep as capability modules until each output path is separately proven resource-backed or ephemeral |
| `transcription` | Server domain remains the reusable audio-to-text capability used by voice notes; model cache/sidecar state is runtime infrastructure | Keep; audit retained transcript outputs separately if direct transcription results become durable |
| `voice_notes` | Now resource-backed through `artifact` and `materialized_file`; list/delete use resource truth | Converted; remove any future file-scan compatibility proposals |

## 2026-05-19 Product-Shell Reachability And Prompt-Library Conversion Pass

This pass converted the other active chat-product durable-output domain and
added a dedicated reachability proof map for the remaining fixed iOS shells.
No product shell was deleted: every listed surface still has a live entrypoint,
client/server dependency, test, or current operator role.

| Area | Evidence | Decision |
|------|----------|----------|
| Product-shell reachability | `docs/product-shell-reachability-map.md` maps AgentControl, SourceChanges, subagent sheets/plugins, notification inbox/detail views, Prompt Library, display stream views, and voice recording affordances by entrypoint, DTO/client, server/event dependency, tests, role, and decision | Keep as the deletion bar for the remaining product shell |
| Prompt history | `engine/tests/prompt_library_resources.rs` proves `prompt_library::history_record/list/delete/clear` use `artifact:prompt-history:*` resources, dedupe by normalized text hash, run with retired prompt tables absent, and skip disabled/cron captures without accepted refs | Converted; old `prompt_history` rows are not runtime truth and fresh v3 schema no longer creates the table |
| Prompt snippets | The same test module proves `prompt_library::snippet_create/update/delete/list/get` use `artifact:prompt-snippet:*` resources, return `resourceRefs` for mutations, discard lifecycle on delete, and run with retired prompt tables absent | Converted; old `prompt_snippets` rows are not runtime truth and fresh v3 schema no longer creates the table |
| Prompt-library contracts | `prompt_library::history_record/delete/clear` and `prompt_library::snippet_create/update/delete` declare artifact-backed output contracts and additive top-level `resourceRefs` | Keep stable public ids/current response fields; no fallback DTO reader |
| iOS Prompt Library | `PromptLibrarySheet`, `PromptLibraryState`, and `PromptLibraryClient` still call canonical `prompt_library::*` capabilities and Decodable DTOs tolerate additive `resourceRefs` | Keep thin shell; no local policy/resource truth |
| Static gates | `product_shell_reachability_and_prompt_library_resources_stay_enforced` requires the reachability map, resource-backed prompt contracts, engine-host resource composition, deleted prompt store, and focused prompt-resource tests | Keep as absence proof against DB-backed prompt truth |

Removal proof from this pass:

- No active iOS product shell met the deletion bar. AgentControl,
  SourceChanges, subagent sheets/plugins, notification inbox/detail, Prompt
  Library, display stream views, and voice recording affordances remain
  classified with evidence in the reachability map.
- No prompt-library storage compatibility path was added. The
  modular-engine-v3 clean break removes legacy prompt tables from fresh active
  schema creation; old databases are archived rather than read or migrated.
- No iOS change was needed: the existing Swift response DTOs ignore additive
  `resourceRefs`, and mutations still go through canonical server
  capabilities.

## Deferred High-Scrutiny Areas

These areas are not proven removable in this checkpoint and need separate
call-graph/test-backed passes:

- `notifications`: still drives APNs, notification inbox, and engine-delivered
  operator notices. Remove only after notification delivery is replaced by
  resource/control projections or a generated surface.
- `AgentControl`, `SourceChanges`, and subagent sheets: still have chat-sheet
  callers and event-state dependencies. Replace with resource lineage/control
  projections before deletion.
- `browser`, `display`, `device`, and `transcription` server domains: still
  register capability workers and may support chat or local device flows.
  Demote or remove only with route, DTO, and event-plugin proof.
- `prompt_library` and `voice_notes` are no longer durable-output ambiguity
  blockers: both now use resources as runtime truth, though their chat/iOS
  affordances remain as thin shells.
- Engine test ownership is no longer a broad-file blocker: the root is
  declaration-only, fixtures are isolated in `engine/tests/support.rs`, and
  behavior tests live in concern-owned files.

## 2026-05-19 Domain Test Ownership And Retired Prompt Schema Cleanup

This pass closed two proof blockers without changing public capability ids or
wire schemas.

| Area | Evidence | Decision |
|------|----------|----------|
| Memory retain tests | `domains/memory/retain/tests/` has declaration-only `mod.rs`, shared `support.rs`, and concern files for formatting, parsing, writers, handler/event flow, interactive ids, and interactive serialization | Keep split; old `tests.rs` stays absent |
| MCP product protocol tests | `domains/mcp/product_protocol/tests/` owns stdio client protocol, manager lifecycle, router/schema refresh, and capability-index behavior separately | Keep split; shared mock server fixtures stay in `support.rs` |
| Session command tests | `domains/session/commands/tests/` separates archive/delete from archive-older-than behavior with shared repo/context setup in `support.rs` | Keep split; old broad test file stays absent |
| Retired prompt schema | Storage generation is `modular-engine-v3`; fresh consolidated schema no longer creates `prompt_history`, `prompt_snippets`, `idx_prompt_history_*`, or `idx_prompt_snippets_*` | Remove with clean-break storage boundary; no migration reader, compatibility table reader, or row-copy path |
| Prompt Library resources | Prompt Library tests assert resource-backed history/snippet behavior when retired tables are absent | Keep `artifact:prompt-*` resources as durable truth |

## 2026-05-19 Product-Shell Readiness, Dependency Hygiene, And Mac Audit

This pass added proof and static gates without deleting an active product shell
or changing runtime behavior.

| Area | Evidence | Decision |
|------|----------|----------|
| Product-shell replacement readiness | `docs/product-shell-reachability-map.md` now records replacement candidate, blocking gap, deletion risk, next prerequisite, and phase decision for AgentControl, SourceChanges, subagent sheets/plugins, notification inbox/detail views, Prompt Library, display stream views, and voice recording affordances | Defer every remaining fixed shell with proof; delete only after generated/resource replacement covers the current operator role |
| Dependency/dead-code tooling | `docs/production-grade-codebase-audit.md` records local checks for `cargo machete`, `cargo udeps`, `cargo llvm-cov`, and `periphery` and defers each with revisit criteria | Keep current CI/static gates as authoritative until optional tools are pinned and low-noise |
| Mac app focused audit | `docs/production-grade-codebase-audit.md` now classifies Mac menu bar, onboarding wizard, server lifecycle, pairing/local connection, observability/feedback, bundled resources, generated project/signing config, helper scripts, and tests | Keep Mac as platform/support thin client; no Mac policy, grant, package trust, resource truth, or generated UI action construction ownership |
| Static gates | `production_grade_codebase_audit_and_rubric_stay_current` and `product_shell_reachability_and_prompt_library_resources_stay_enforced` require the new readiness, dependency-tooling, and Mac audit evidence | Keep gates as drift protection for the 98/100 repo-wide checkpoint |

## 2026-05-19 Prompt Library Generated Management Conversion

This pass converted Prompt Library management from fixed Swift controls to
server-authored generated UI while preserving the local composer insertion
picker.

| Area | Evidence | Decision |
|------|----------|----------|
| Generated UI authoring | `ui::surface_for_target` supports `targetType = "resource_collection"` only for `prompt_library.snippets.v1` over `artifact:prompt-snippet` and `prompt_library.history.v1` over `artifact:prompt-history` | Keep narrow v1 target; no dynamic catalog or generic client-authored action path |
| Prompt Library management | Rust generated UI tests prove snippet/history surfaces include bounded artifact previews, resource refs, schema-valid stored actions, and `ui::submit_action` child lineage | Manage snippets/history through generated `ui_surface` resources and canonical `prompt_library::*` actions |
| iOS fixed shell | `PromptLibrarySheet` no longer owns add/edit/delete/clear controls; `PromptLibraryManagementSurfaceSheet` requests the two resource-collection surfaces and submits stored UI action coordinates only | Keep fixed sheet only as local prompt picker/composer insertion affordance |
| Renderer state | `GeneratedUISurfaceView` seeds form state from server-provided `value` props and keeps stale/expired/damaged/offline action handling closed | Keep iOS as renderer/action submitter; no target function, payload template, grant, or policy construction |
| Static gates | `product_shell_reachability_and_prompt_library_resources_stay_enforced` and iOS source guards require generated Prompt Library management and absence of fixed management symbols | Keep gates as proof for generated management and the selection-only composer picker |

## 2026-05-19 Prompt Library Composer Boundary Decision

This pass closed the final product-shell ambiguity without adding a generated
handoff. Selecting prompt text into an unsent composer draft is local editing
state, not durable engine truth, so the picker remains as a gated thin shell.

| Area | Evidence | Decision |
|------|----------|----------|
| Composer insertion | `PromptLibrarySheet`, `PromptHistoryListView`, and `PromptSnippetListView` call only `onSelect(text)` / `onSelect(item.text)` / `onSelect(snippet.text)` into the local draft composer | Keep as permanent local editing affordance; no server mutation or durable state is produced by selection |
| Management separation | `PromptLibraryManagementSurfaceSheet` remains the only Prompt Library management path and submits generated UI actions through `ui::submit_action` | Keep generated `ui_surface` management as the mutation boundary |
| Client policy boundary | Swift and Rust static gates forbid target function ids, payload templates, grants, lineage, or `UiActionSubmissionDTO` construction in the picker/state/list files | Keep iOS free of policy/action construction in the composer picker |
| Scorecard closure | `docs/production-grade-rubric.md` reaches `100/100` only because the remaining fixed shell is explicitly classified, documented, and guarded | Treat future fixed shells the same way: generated/resource replacement or proof-backed local affordance |

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

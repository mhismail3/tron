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

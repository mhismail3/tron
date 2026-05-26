# Capability-Backed Truth Migration Plan

Last scored: 2026-05-26 on `next/modular-capability-engine`.

This document tracks the migration from a well-classified codebase to **100%
capability-backed truth**. The standard here is stricter than the repo-wide
production-grade rubric: every durable fact that can affect agent behavior,
operator state, future prompts, user-visible state, retries, approvals, or
background work must be owned by the collapsed engine substrate and reachable
through canonical capabilities.

Domain-owned hidden file/table truth is not acceptable unless it is explicitly
classified as low-level platform substrate with static gates and no agent-policy
role.

Current capability-backed-truth score: **100/100**.

The repo-wide production-grade score remains useful as a reachability,
organization, and classification score. This score tracks a narrower question:
whether all meaningful truth is capability-owned, resource/decision/evidence/
invocation/grant backed, inspectable, and recoverable.

## Rubric

| Axis | Points | Current | 100% Definition |
|---|---:|---:|---|
| Capability-owned durable truth | 20 | 20 | Every agent- or operator-affecting durable fact is resource/decision/evidence/invocation/grant backed or explicitly accepted substrate |
| Agent orchestration path | 15 | 15 | Model-facing `execute` can resolve, prepare, approve, run, observe, and self-correct across all core capabilities |
| Resource/output contracts | 15 | 15 | Mutating durable outputs declare contracts and return refs; failures leave no accepted hidden output |
| Authority and security | 15 | 15 | Grants, approvals, file/network policy, redaction, and sandboxing are enforced at every boundary |
| Background/autonomous work | 10 | 10 | Auto-retain, scheduled work, notifications, retries, and cleanup all run through canonical invocations and leave evidence |
| Client thinness | 8 | 8 | iOS/Mac render server truth and submit stored actions only; local state is limited to genuine editing/hardware affordances |
| Observability and recovery | 7 | 7 | Operators and agents can inspect lineage, state, failure, safe next action, and recovery path |
| Test/static proof | 7 | 7 | Focused tests, integration tests, failure tests, absence gates, and docs prove the invariant |
| Deletion discipline | 3 | 3 | Retired files/tables/routes/fallbacks are removed or statically forbidden |

Total: **100/100**.

## Known Blockers

| Blocker | Current Truth Owner | Why It Blocks 100% | Target Decision |
|---|---|---|---|
| None | none | No unclassified durable state owner remains after accepting cron runtime tables as low-level scheduler cache with static gates and recovery tests | Keep gates current when new durable state or background work is added |

## Completed Conversions

| Conversion | Substrate Truth | Evidence |
|---|---|---|
| Memory retain | `memory::retain` and hidden `memory::auto_retain_fire` now persist retained journals, rule updates, and arguments as `artifact` resources with linked `materialized_file` markdown projections. `memory.retained` payloads include `resourceRefs` plus recovery/projection `evidenceRefs`, duplicate retain keys do not duplicate memory artifacts, and prompt context appends retained rule/argument artifacts from resource truth. | `packages/agent/src/domains/memory/retain/resources.rs`; `packages/agent/src/engine/tests/memory_retain_resources.rs`; `packages/agent/src/domains/agent/runtime/service/context.rs`; `packages/agent/tests/threat_model_invariants.rs` |
| Notifications | `notifications::send` persists bounded `notification` resources, delivery `evidence`, and read-state `decision` resources; `notifications::list` reads resource/decision truth and ignores historical event-only rows; generated `notifications.inbox.v1` surfaces expose stored mark-read actions. | `packages/agent/src/domains/notifications/inbox.rs`; `packages/agent/src/engine/tests/notification_resources.rs`; `packages/agent/src/engine/primitives/ui.rs`; `packages/agent/tests/threat_model_invariants.rs` |
| Subagent lineage | Completed child-agent results are persisted as deterministic `agent_result:subagent:{subagentSessionId}` resources; `agent::subagent_status` and `agent::subagent_result` reconstruct completed output from resource truth even without a live manager; malformed, mismatched, or cross-session resources are rejected before they become status/result truth; generated `subagent.lineage.v1` surfaces expose bounded lineage rows and stored canonical status/result/cancel actions. Fixed iOS subagent sheets remain thin chat navigation/rendering affordances and are statically forbidden from constructing target functions, payload templates, grants, or action submissions. | `packages/agent/src/domains/agent/lineage.rs`; `packages/agent/src/domains/agent/operations/submissions.rs`; `packages/agent/src/domains/agent/runner/orchestrator/subagent_manager/execution.rs`; `packages/agent/src/engine/tests/subagent_lineage.rs`; `packages/agent/src/engine/primitives/ui.rs`; `packages/agent/tests/threat_model_invariants.rs` |
| Source-control and AgentControl surfaces | Generated `source_control.session.v1` surfaces project session-scoped git/worktree invocation truth, bounded changed-file/status/conflict summaries, and stored canonical `worktree::*` / `git::*` actions. Generated `agent_control.session.v1` surfaces expose session/catalog/control summaries plus a stored action that opens the source-control review surface. Fixed Swift shells remain thin navigation/review containers and are statically forbidden from constructing generated action targets, payload templates, grants, or action submissions. | `packages/agent/src/engine/primitives/ui.rs`; `packages/agent/src/engine/tests/generated_ui.rs`; `packages/agent/src/engine/resources/ui_surface.rs`; `packages/agent/tests/threat_model_invariants.rs` |
| Cron schedule and run observations | `cron::create`, `cron::update`, `cron::delete`, `cron::list`, and `cron::run` bind schedule definitions from `decision:cron-schedule:*` resources; `cron::get_runs` reads bounded `evidence:cron-run:*` resources; run completion attaches evidence; one-shot and auto-disabled lifecycle flips update the schedule decision. `cron_jobs` and `cron_runs` are accepted low-level scheduler cache for due-time, retry, running-state, stuck-run, and executor mechanics only. Cache-only rows are not product truth, manual runs reject jobs without decisions, and decision truth can rehydrate an empty runtime cache. | `packages/agent/src/domains/cron/implementation/domain/truth.rs`; `packages/agent/src/domains/cron/operations/jobs.rs`; `packages/agent/src/domains/cron/operations/runs.rs`; `packages/agent/src/domains/cron/callbacks.rs`; `packages/agent/src/engine/tests/cron_resources.rs`; `packages/agent/tests/threat_model_invariants.rs` |

## Conversion Candidate Register

| Candidate | Classification | Score Target | Phase | Acceptance Criteria |
|---|---|---:|---|---|
| Memory retain | completed durable agent-context truth | 94/100 | Phase 1 | Retained journal/rule/argument outputs are resource-backed, events include refs, context loads resource truth, direct durable file writes are forbidden outside materialization helpers |
| Notifications | completed operator attention truth | 96/100 | Phase 2 | Send/list/read state is resource/decision/evidence backed; generated inbox surfaces expose canonical read actions; retired read-state truth is absent with gates |
| Subagent invocation/result surfaces | completed execution lineage projection | 97/100 | Phase 3 | Completed child result state survives resume/restart through deterministic `agent_result` resources; malformed or cross-session resources are ignored; generated lineage surfaces render server-owned resource/invocation truth and stored canonical actions; fixed client shells remain thin |
| Source-control and AgentControl surfaces | completed operator review projection | 98/100 | Phase 4 | Git/worktree/control review surfaces are server-authored, revision-pinned, stale-safe, and use stored canonical actions while fixed Swift shells stay thin |
| Cron and scheduled work | completed schedule/run truth with accepted scheduler cache | 100/100 | Phase 5 + Phase 6 | Schedules are `decision` resources, completed runs are `evidence`, mutating contracts return refs, `automations.json` is test-only, cache-only rows are ignored by public truth, and manual runs rehydrate cache from decisions |
| Whole-engine audit | final proof | 100/100 | Phase 6 | No unclassified durable truth, hidden file/table state, client policy, fallback reader, or retired route remains |

## Phase Tracker

### Phase 0: Plan, Audit, And Score Reset

Status: **completed**.

Target score: **90/100**.

Required work:

- Add this document as the durable capability-backed-truth tracker.
- Update the production-grade rubric to distinguish the existing 100/100
  classification score from this stricter 90/100 capability-backed-truth score.
- Update the cleanup audit and product-shell reachability map so memory retain is
  a first-class conversion blocker.
- Add static gates requiring this tracker, all rubric axes, current score, phase
  tracker, conversion candidates, and cross-document references.

Acceptance:

- No runtime behavior changes.
- Docs honestly state that classification is strong but capability-backed truth
  is not complete.
- Static gates prevent memory retain, notifications, cron, subagent lineage,
  source-control/AgentControl surfaces, and final audit work from disappearing
  from the tracker.
- Converted domains must have no direct hidden durable write.

### Phase 1: Memory Retain Resource Conversion

Status: **completed**.

Target score: **94/100**.

Required behavior:

- Keep public capability ids: `memory::retain` and hidden
  `memory::auto_retain_fire`.
- Add durable output contracts for memory retain capabilities.
- Represent retained outputs as substrate truth:
  - `artifact:memory-journal:{sessionId}:{rangeHash}`;
  - `artifact:memory-rule:{ruleId}:{revision}`;
  - `artifact:memory-argument:{slug}:{revision}`;
  - linked `materialized_file` projections for markdown paths.
- Replace direct durable writes in memory retain with canonical resource and
  materialization creation.
- Treat `~/.tron/memory/...` markdown as projection/materialization, not source
  truth.
- Update memory events to include `resourceRefs` and evidence refs.
- Update context injection to read resource truth or verified resource-linked
  projections, not raw filesystem scans as authoritative memory state.
- Keep manual retain high-risk/approval-gated; auto-retain remains internal but
  still invokes canonical capability paths and records lineage.

Failure rules:

- Summarizer failure may produce bounded recovery evidence, but not accepted
  memory resources unless the recovery output validates.
- Resource persistence failure prevents materialization and prevents successful
  `memory.retained`.
- Materialization failure leaves resource truth intact and records evidence.
- Duplicate retain idempotency must not duplicate memory artifacts,
  materialized files, or retained events.

Required tests:

- Manual retain produces artifact/materialized refs and no direct hidden durable
  write.
- Auto-retain invokes `memory::auto_retain_fire`, then resource-backed retain
  work.
- Duplicate manual/auto retain replays or skips cleanly.
- Failed summarizer/resource/materialization paths leave inspectable evidence.
- Context snapshot includes memory from resource-backed truth.
- Static gates forbid `OpenOptions`, direct `fs::write`, or raw filesystem
  source-truth scans in memory retain production code outside materialization
  helpers.

### Phase 2: Notification Resource Contract And Generated Inbox

Status: **completed**.

Target score: **96/100**.

Required behavior:

- Keep public ids: `notifications::send`, `notifications::list`,
  `notifications::mark_read`, and `notifications::mark_all_read`.
- Add a `notification` resource kind only if `artifact` would make lifecycle,
  read, delivery, severity, or attention semantics ambiguous.
- Store notification delivery facts as resources and evidence.
- Store read/dismiss/mark-all state as `decision` resources.
- Make `notifications::list` read resource/decision truth, not session events or
  `notification_read_state`.
- Author generated notification inbox surfaces over server resource truth.
- Remove the retired notification read-state table through a clean storage
  generation reset.

Required tests:

- Send creates notification resource/evidence and returns refs.
- Push failure records delivery evidence without fabricating success.
- List ignores old unregistered notification events.
- Mark-read and mark-all create decisions and are idempotent.
- Generated inbox actions submit only stored action coordinates.
- Static gates forbid notification read-state table truth and event-payload
  reconstruction.

### Phase 3: Subagent, Invocation, And Result Lineage Surfaces

Status: **completed**.

Target score: **97/100**.

Implemented behavior:

- Keep existing `agent::*` capabilities stable.
- Completed subagent outputs are persisted as deterministic
  `agent_result:subagent:{subagentSessionId}` resources.
- `agent::subagent_status` and `agent::subagent_result` read completed result
  truth from resources first, then fall back only to the live manager for truly
  active jobs.
- Resource-backed status/result reads require matching deterministic resource
  id, parent session scope, `parentSessionId`, and `subagentSessionId`; malformed
  or cross-session resources are treated as not ready.
- `ui::surface_for_target` authors constrained `resource_collection` surfaces
  for `targetId = "agent_result:subagent"` and
  `layoutProfile = "subagent.lineage.v1"`.
- Generated subagent lineage surfaces expose bounded resource/invocation rows
  plus stored canonical `agent::subagent_status`, `agent::subagent_result`, and
  `agent::cancel_subagent` actions.
- Generated lineage surfaces use the caller session context when present and
  omit malformed, mismatched, or cross-session rows.
- Fixed chat chips/sheets remain as thin local rendering/navigation
  affordances; static gates forbid them from constructing target functions,
  payload templates, grants, action submissions, or capability policy.

Completed tests:

- `subagent_result_and_status_read_resource_truth_without_live_manager`.
- `generated_subagent_lineage_surface_uses_resource_truth_and_stored_actions`.
- `malformed_or_cross_session_subagent_resources_are_not_lineage_truth`.
- `subagent_lineage_resource_truth_boundary_stays_enforced`.

### Phase 4: Source-Control And AgentControl Generated Surfaces

Status: **completed**.

Target score: **98/100**.

Required behavior:

- Add generated `source_control.session.v1` surfaces that derive session-scoped
  source-control review state from existing git/worktree invocation records and
  bounded capability results.
- Add generated `agent_control.session.v1` surfaces that expose session/catalog
  summary state and route source-control review through a stored
  `ui::surface_for_target` action.
- Keep fixed AgentControl/SourceChanges Swift shells as navigation/review
  containers only until generated UI fully replaces every bespoke workflow.
- Keep every mutation routed through canonical `git::*`, `worktree::*`,
  `control::*`, and `ui::*` capabilities.

Required tests:

- `ui_surface_for_target_authors_source_control_session_surface` proves bounded
  source-control projection layout and stored canonical worktree/git actions.
- `ui_surface_for_target_authors_agent_control_session_surface` proves the
  AgentControl generated surface and stored source-control handoff action.
- `product_shell_reachability_and_prompt_library_resources_stay_enforced`
  statically forbids AgentControl/SourceChanges Swift shells from constructing
  generated action targets, payload templates, grants, or action submissions.

### Phase 5: Cron And Scheduled Work Truth Decision

Status: **completed to 99/100**.

Target score: **99/100**.

Decision: convert operator/product truth now, then leave final cache removal or
formal low-level-substrate acceptance to Phase 6. Phase 6 accepted the cache as
substrate after proving public truth does not depend on cache-only rows.

Required behavior:

- Represent schedule definitions as `decision:cron-schedule:*` resources.
- Represent completed run observations as bounded `evidence:cron-run:*`
  resources linked to the schedule decision.
- Keep `cron_jobs` and `cron_runs` as scheduler runtime cache only: timer wakeup,
  running-state, retry, stuck-run, and short-lived executor mechanics.
- Keep `automations.json` loaders/savers as test-only fixtures; production
  create/update/delete/list no longer use the file.
- Keep lifecycle flips synchronized from runtime back to decision truth for
  one-shot completion and auto-disable after consecutive failures.

Required tests:

- `cron_create_update_delete_are_decision_backed` proves mutating schedule
  operations return decision refs and list/get read decision truth.
- `cron_get_runs_reads_evidence_truth` proves completed run observations are
  listed from evidence truth.
- Static gates keep `automations.json` production readers out of cron
  operations and require run listing to use evidence truth.
- Static gates require docs to classify `cron_jobs` / `cron_runs` as scheduler
  runtime cache, not product truth.

### Phase 6: Final Whole-Engine Capability-Backed Audit

Status: **completed**.

Target score: **100/100**.

Required behavior:

- Re-run the full conversion candidate audit across Rust agent, engine
  primitives, domains, iOS, Mac, scripts, schemas, generated projects, and docs.
- Update this scorecard with final evidence.
- Add absence gates for every removed file/table/route/fallback.
- Verify model-facing `execute` can discover, inspect through execution
  diagnostics, and use every core capability shape without requiring hidden
  search/inspect tools.
- Update README, architecture docs, cleanup audit, product-shell reachability
  map, and ledger.

Completed decision:

- `cron_jobs` and `cron_runs` remain accepted low-level scheduler substrate
  rather than product truth. Removing them would reimplement timer wakeup,
  retry, running-state, and stuck-run mechanics under another name without
  improving operator truth.
- Public cron schedule operations read/write `decision:cron-schedule:*`
  resources, not cache rows.
- Public cron run listing reads `evidence:cron-run:*`, not `cron_runs`.
- Manual `cron::run` now loads the schedule decision first, rejects cache-only
  or disabled schedules before execution, and rehydrates an empty runtime cache
  from decision truth.
- Static gates forbid production `automations.json` truth, require cron run
  operations to bind from decisions/evidence, and keep the cache classified in
  README/docs.
- `capability::execute` remains the single model-facing capability primitive.
  Operator/internal catalog search and inspect remain engine-owned debugging
  surfaces, while execution diagnostics and `capability.orchestration` audit
  events expose resolve/prepare/run/observe state.

Completed tests:

- `cron_runtime_cache_rows_are_not_product_truth`.
- `cron_run_rehydrates_runtime_cache_from_decision_truth`.
- `cron_run_rejects_disabled_schedule_decision`.
- Existing conversion tests for memory retain, notifications, subagent
  lineage, source-control/AgentControl generated surfaces, cron schedule/run
  resources, generated UI, resource kernel, and threat-model invariants.

Final acceptance:

- No unclassified durable state owner remains.
- No domain-owned hidden file/table truth affects agent behavior.
- No client-owned grant, lineage, action-template, or policy path remains.
- Every mutating capability has output contracts, idempotency behavior, failure
  proof, and inspectable lineage.
- Every autonomous workflow runs through canonical invocation/capability paths.
- full CI, targeted iOS/Mac checks, static gates, and forbidden-symbol scans
  pass.

## Verification Standard For Every Phase

Each phase must ship code, tests, docs, static gates, and ledger together.

Required checks:

- Focused Rust tests for the touched domain.
- `cargo test generated_ui --lib -- --nocapture` when generated surfaces change.
- `cargo test resource_ --lib -- --nocapture` when resource contracts change.
- `cargo test --test threat_model_invariants -- --nocapture`.
- `RUSTFLAGS="-D warnings" cargo check --all-targets` for broad Rust changes.
- `git diff --check`.
- `scripts/tron ci fmt check clippy test` before checkpoint commits.
- iOS/Mac `xcodegen generate` and targeted tests only when client/project files
  change.

Audit loop:

- Before implementation: add or identify failing/covering tests.
- During implementation: keep public ids stable unless the phase explicitly
  authorizes a clean break.
- After implementation: inspect diffs for fallback readers, compatibility paths,
  raw file/table truth, dead code, and duplicate state planes.
- Before commit: update this score and explain why it changed.

## Assumptions

- Existing execute-orchestration changes are separate and must not be
  overwritten by this migration tracker.
- Storage generation may bump only for clean-break removal of retired
  tables/files; no compatibility readers or row-copy migrations are added.
- Existing public capability ids stay stable unless a later phase explicitly
  chooses a clean break.
- `artifact`, `decision`, `evidence`, `materialized_file`, invocations, grants,
  queues, leases, and generated UI remain the preferred substrate.
- New resource kinds are allowed only when generic `artifact` would hide
  lifecycle semantics or weaken operator explainability.
- Local iOS/Mac affordances are allowed only for true local editing/hardware
  interactions; durable truth and policy stay server-owned.

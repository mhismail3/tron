# Capability-Backed Truth Migration Plan

Last scored: 2026-05-25 on `next/modular-capability-engine`.

This document tracks the migration from a well-classified codebase to **100%
capability-backed truth**. The standard here is stricter than the repo-wide
production-grade rubric: every durable fact that can affect agent behavior,
operator state, future prompts, user-visible state, retries, approvals, or
background work must be owned by the collapsed engine substrate and reachable
through canonical capabilities.

Domain-owned hidden file/table truth is not acceptable unless it is explicitly
classified as low-level platform substrate with static gates and no agent-policy
role.

Current capability-backed-truth score: **90/100**.

The repo-wide production-grade score remains useful as a reachability,
organization, and classification score. This score tracks a narrower question:
whether all meaningful truth is capability-owned, resource/decision/evidence/
invocation/grant backed, inspectable, and recoverable.

## Rubric

| Axis | Points | Current | 100% Definition |
|---|---:|---:|---|
| Capability-owned durable truth | 20 | 16 | Every agent- or operator-affecting durable fact is resource/decision/evidence/invocation/grant backed or explicitly accepted substrate |
| Agent orchestration path | 15 | 14 | Model-facing `execute` can resolve, prepare, approve, run, observe, and self-correct across all core capabilities |
| Resource/output contracts | 15 | 13 | Mutating durable outputs declare contracts and return refs; failures leave no accepted hidden output |
| Authority and security | 15 | 15 | Grants, approvals, file/network policy, redaction, and sandboxing are enforced at every boundary |
| Background/autonomous work | 10 | 7 | Auto-retain, scheduled work, notifications, retries, and cleanup all run through canonical invocations and leave evidence |
| Client thinness | 8 | 7 | iOS/Mac render server truth and submit stored actions only; local state is limited to genuine editing/hardware affordances |
| Observability and recovery | 7 | 6 | Operators and agents can inspect lineage, state, failure, safe next action, and recovery path |
| Test/static proof | 7 | 6 | Focused tests, integration tests, failure tests, absence gates, and docs prove the invariant |
| Deletion discipline | 3 | 3 | Retired files/tables/routes/fallbacks are removed or statically forbidden |

Total: **90/100**.

## Known Blockers

| Blocker | Current Truth Owner | Why It Blocks 100% | Target Decision |
|---|---|---|---|
| Memory retain | Markdown files under `~/.tron/memory/` and `~/.tron/workspace/knowledge/arguments/` | Auto-retain can affect future prompts through direct file truth outside resource contracts | Convert to artifact/materialized-file truth first |
| Notifications | Session events plus notification read-state storage and fixed iOS inbox/detail surfaces | Operator attention/read state is not resource/decision backed | Convert to notification resources, decision read receipts, and generated inbox/detail |
| Subagent sheets/results | Fixed event/plugin/client projections | Child execution lineage is not fully rendered through generated invocation/resource surfaces | Convert fixed sheets to generated lineage surfaces |
| Source-control and AgentControl shells | Fixed Swift product shells plus domain/event projections | Review workflows still contain client-shaped operator surfaces | Convert only after generated review surfaces preserve current safety |
| Cron/scheduled work | `automations.json`, `cron_jobs`, and `cron_runs` | Scheduler product truth remains outside resource/decision truth | Convert unless explicitly accepted as low-level scheduler substrate |
| Migration tracker | Previously no capability-backed-truth scorecard | Progress could be claimed as complete from classification alone | Keep this document and static gates current |

## Conversion Candidate Register

| Candidate | Classification | Score Target | Phase | Acceptance Criteria |
|---|---|---:|---|---|
| Memory retain | durable agent-context truth | 94/100 | Phase 1 | Retained journal/rule/argument outputs are resource-backed, events include refs, context loads resource truth, direct durable file writes are forbidden outside materialization helpers |
| Notifications | operator attention truth | 96/100 | Phase 2 | Send/list/read state is resource/decision/evidence backed; fixed inbox/detail is replaced by generated surfaces; retired read-state truth is absent or ignored with gates |
| Subagent invocation/result surfaces | execution lineage projection | 97/100 | Phase 3 | Child invocation/result state survives resume and renders from server-authored generated lineage surfaces |
| Source-control and AgentControl surfaces | operator review projection | 98/100 | Phase 4 | Git/worktree/control review surfaces are server-authored, revision-pinned, and stale-safe before fixed mutation UI is removed |
| Cron and scheduled work | scheduler product truth | 99-100/100 | Phase 5 | Schedules/runs are resource/decision/invocation/evidence backed, or cron is explicitly accepted as low-level substrate with static gates |
| Whole-engine audit | final proof | 100/100 | Phase 6 | No unclassified durable truth, hidden file/table state, client policy, fallback reader, or retired route remains |

## Phase Tracker

### Phase 0: Plan, Audit, And Score Reset

Status: **in progress**.

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

Status: **pending**.

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

Status: **pending**.

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
- Replace fixed iOS inbox/detail with generated notification inbox/detail
  surfaces after server truth is proven.
- Remove or ignore retired notification read-state table through a clean storage
  generation reset if table removal is required.

Required tests:

- Send creates notification resource/evidence and returns refs.
- Push failure records delivery evidence without fabricating success.
- List ignores old unregistered notification events.
- Mark-read and mark-all create decisions and are idempotent.
- Generated inbox actions submit only stored action coordinates.
- Static gates forbid notification read-state table truth and fixed inbox
  mutation policy.

### Phase 3: Subagent, Invocation, And Result Lineage Surfaces

Status: **pending**.

Target score: **97/100**.

Required behavior:

- Keep existing `agent::*` capabilities stable.
- Ensure subagent spawn/status/result records have complete invocation lineage
  and resource refs.
- Author generated list/detail surfaces for child invocations, pending states,
  results, failures, and recovery actions.
- Replace fixed result/detail sheets only after generated surfaces match active
  UX.
- Keep chat chips as thin entrypoints if they only open server-authored lineage
  surfaces.

Required tests:

- Child invocation lineage survives resume/restart.
- Generated subagent detail shows pending, completed, failed, cancelled, and
  retried states.
- Fixed subagent sheets no longer own durable state or result interpretation.
- Static gates forbid client-owned subagent policy and stale event-only result
  truth.

### Phase 4: Source-Control And AgentControl Generated Surfaces

Status: **pending**.

Target score: **98/100**.

Required behavior:

- Define generated surfaces for source changes, worktree status, diff summaries,
  conflict state, deferred prompts, and canonical git/worktree actions.
- Keep local UI only for true composition/editing affordances that have no
  durable engine state until submitted.
- Move source-control action consequence summaries to server-owned capability
  metadata and action summaries.
- Remove fixed management controls once generated surfaces are equivalent.

Required tests:

- Generated source-control review surfaces are revision-pinned and stale-safe.
- Mutating git/worktree actions require the same approvals and output contracts
  as direct capability use.
- iOS submits only stored generated action coordinates.
- Static gates protect against fixed shell mutation returning.

### Phase 5: Cron And Scheduled Work Truth Decision

Status: **pending**.

Target score: **99/100** if classified with proof, **100/100** if converted.

Default decision: convert scheduled work truth unless implementation proves the
scheduler must remain low-level substrate.

Required behavior:

- Represent schedules as `decision` or `goal` resources with cadence, scope,
  grant ceiling, actor, expiry, and target action.
- Represent runs as invocations plus evidence.
- Keep queue/lease internals as substrate, not product truth.
- Remove domain-owned `automations.json`, `cron_jobs`, and `cron_runs` as
  authoritative truth through a clean storage-generation reset if conversion is
  feasible.
- If conversion is deferred, document cron as accepted scheduler substrate with
  explicit limits and static gates.

Required tests:

- Create/update/delete/list/run schedule operations read/write resource/decision
  truth.
- Missed/retried runs leave evidence and no duplicate invocations.
- Old scheduler tables/files are absent from fresh current storage if
  converted.
- Static gates forbid reintroducing hidden scheduler product truth.

### Phase 6: Final Whole-Engine Capability-Backed Audit

Status: **pending**.

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

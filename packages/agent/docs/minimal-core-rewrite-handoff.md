# Minimal Core Rewrite — Paused Feature Handoff

> **Status:** paused, work in progress, intentionally unadvertised
> **Checkpoint date:** 2026-08-11
> **Feature branch:** `codex/minimal-core-rewrite`
> **Starting commit:** `53aafbdfacf37f82927dadeb1ed2421247d58a1f`
> **Merge base:** `85e62a3337e2c8d28496e0e5f4f73e52600ad6be`
> (`origin/main` at checkpoint time)

This document is the restart point for Tron's paused minimal-core rewrite. It
distinguishes code which is already validated, code which is present but
unadvertised, and integration code which is still incomplete. Do not infer
production readiness merely because a schema, service, or handler exists.

The starting commit is itself a substantial, previously validated feature: it
contains the first-class reusable-agent implementation built on the existing
Worker Kernel, its durable coordination/recovery hardening, and the cohesive
iOS Agents management experience. The uncommitted work which followed that
commit begins a more fundamental replacement of the Worker architecture.

## Why this branch exists

The Worker abstraction currently combines too many unrelated concepts:

- model tools and typed contracts;
- reusable instructions and scripts;
- agent presets and roles;
- immutable packages and dependency installation;
- command, agent, and resident-service execution;
- schedules, events, webhooks, notifications, and artifacts;
- durability, results, cancellation, causal topology, and UI presentation.

The rewrite separates reusable behavior from Engine custody. Files, scripts,
agent-authored skills, and small callable modules should own task semantics.
The Engine should own only the durable transitions which cannot be recreated
reliably in a prompt or shell script: sessions, agents, assignments, messages,
waits, results, time, process custody, authority, recovery, and authenticated
native effects.

The intended mental model is:

```text
Files + Shell + Code + Agents + Time
                    |
                    +-- fixed native services when the OS/device is the owner
```

## Frozen architecture decisions

These decisions were settled before the pause. A future implementation should
not casually reintroduce the complexity they remove.

### Exact model surface

The target ordinary model surface is exactly eight stable tools:

1. `read`
2. `write`
3. `edit`
4. `bash`
5. `code`
6. `agent`
7. `schedule`
8. `request_user_input`

`code`, `agent`, and `schedule` are each closed action unions. Reducing the
surface does not mean erasing durable semantics; it means placing related
operations behind one coherent capability instead of projecting many package-
or worker-specific tool schemas.

There is no dynamic model-tool projection in the target architecture. Session
title changes, authenticated client administration, transcript inspection,
promotion, and other product operations remain native/client operations rather
than extra model tools.

### Agents

- `agentId` is a stable, reusable identity with one persistent transcript.
- `assignmentId` is the only unit of queued/running/waiting/terminal work and
  the only causal topology node.
- Attempts are restart evidence, not new identities.
- There is no `executionId`, Worker kind, role version, or skill assignment on
  an agent.
- An agent executes at most one assignment at a time; accepted work is FIFO.
- Semantic message kind determines passive versus actionable behavior. Models
  never choose wake flags or delivery boundaries.
- Waiting is durable parking, never polling. Results still return
  automatically when the caller did not explicitly wait.
- Provider streams and tool calls are never interrupted. Actionable arrivals
  are leased and consumed only at a safe provider boundary.
- Stable child agents remain idle and reusable until explicitly closed or
  promoted.

The eventual single `agent` union must cover discovery/inspection, spawn,
send, wait, offer response, cancellation, configuration, close, and retry.
Promotion and arbitrary transcript access remain authenticated client actions.
Caller identity, idempotency keys, trace IDs, autonomous-hop counts, authority,
and workspace context are Engine-derived, never model input.

### Code and agent-authored capabilities

- Every stable agent receives one logical persistent TypeScript journal.
- QuickJS executes only in a disposable child process. It receives no ambient
  filesystem, environment, network, process, credential, or module-loader
  authority.
- Oxc strips TypeScript before evaluation.
- A logical runtime is rebuilt as one ES module from committed cells plus the
  candidate. This preserves lexical bindings, functions, and top-level
  `await` across process restarts without serializing a hidden heap.
- Only successful cells join the replay prefix. Failed, cancelled, and timed-
  out cells remain audit evidence but do not mutate future lexical state.
- Broker calls are admitted durably and replay by exact operation, canonical
  input, ordinal, and idempotency identity.
- Bash remains the explicit trusted-host escape. It is deliberately not
  embedded inside the QuickJS broker.

Skills are agent-authored packages under explicit profile or trusted-project
roots. A bounded `SKILL.md` supplies progressive-disclosure instructions; an
optional digest-pinned single-file TypeScript/JavaScript module supplies a
direct reusable capability. Skills are not agents, roles, model tools, or
authority grants. They can be invoked directly without starting a subagent,
and may use an Engine-bound isolated SQLite state namespace.

No first-party repository-managed `packages/agent/skills/` tree is allowed.
The clean profile begins with zero skills, and Worker bundles are not
heuristically converted into skills.

### Scheduling

Scheduling is a core durable transition with exactly three substrate-neutral
targets:

- queue an assignment on a reusable agent;
- spawn a fresh agent and its first assignment;
- invoke one namespaced, optionally version-pinned capability.

The schedule definition snapshots Engine-authored authority. It supports one-
time instants and bounded RFC 5545 recurrence in an explicit IANA timezone,
with restart-safe cursor advancement, misfire policy, overlap policy,
idempotent manual runs, occurrence leases, and audit tombstones.

### Fixed native services

Exactly four exceptional native services are planned behind the `code` broker,
not as Workers or ordinary model tools:

- Notifications
- Transcription
- Browser Control
- Mac Control

The registry is closed and source-owned. An unavailable service remains
discoverable with a user-friendly reason; the Engine must not synthesize a
Worker or shell fallback. The current branch contains the registry interfaces,
not the four production adapters.

### Authority and host access

Tron is a trusted local-agent product. `bash` runs as the user's normal OS
principal and is not a sandbox. Workspace write scopes and process/write
claims coordinate concurrent actors; they are not a security boundary against
arbitrary shell code. Do not document them as containment.

The QuickJS runtime is separately capability-empty by construction. Its
effects cross the Engine broker and are checked against the current immutable
assignment grant.

### Storage and migration

New coordination, code-journal, schedule, transcript, wait, result, and wake
truth belongs in `tron.sqlite`. The target has no `workers.sqlite` and no
cross-database coordination outbox.

The migration is an explicit clean break, not an automatic import:

1. Stop Tron.
2. Create and verify a meaningful-data legacy archive.
3. Require the exact archive SHA-256 and explicit reset confirmation.
4. Remove only the documented legacy runtime roots.
5. Preserve auth, settings, vaults, pairing/TCC state, backups, ordinary
   workspace files, and future capability roots.
6. Start the minimal-core build against a newly created canonical database.

Never run the reset command against a real profile merely to test this branch.

### iOS product direction

The existing Agents management UI from the starting commit should be retained
and adapted to core Agent projections. Worker Console and role-review UI should
be replaced by a cohesive Runtime Hub showing Agents, Skills, Automations,
fixed Services, durable results, schedules, and runtime health. Remove
`agent_role_review.v1` and Worker terminology from user-facing surfaces. No iOS
rewrite work was started after the starting commit.

## Current source state

### Advertised versus dormant behavior

This checkout is a hybrid WIP, not the target product:

- The Worker Kernel still registers, activates, dispatches, and owns the live
  provider surface.
- The four new host contracts (`read`, `write`, `edit`, `bash`) are registered,
  but their implementations still delegate to WorkerRuntime custody.
- The current fixed-surface tests were partially adjusted from 27/16 to 24/13;
  the exact eight-tool cutover has **not** happened.
- Core coordination, Agent Execution, scheduling, and persistent code are
  intentionally unadvertised.
- No new `agent`, `code`, or `schedule` FunctionContract/handler is registered.
- Worker contracts, Worker UI, `workers.sqlite`, roles, role review, dynamic
  packages, and legacy projections have not been deleted.
- The new Agent Execution lifecycle is not activated at server startup.

This all-at-once gate is intentional: do not expose spawning without complete
communication, waits, recovery, result return, cancellation, Team Context, and
operator observability.

### New and materially changed areas

#### Minimal host primitives

Files:

- `src/domains/host/mod.rs`
- `src/domains/host/contract.rs`
- `src/domains/host/handlers.rs`
- `src/domains/host/process_custody.rs`
- `src/domains/host/tests.rs`

Implemented:

- closed `read`, `write`, `edit`, and `bash` contracts;
- directory listing as a `read` mode;
- atomic write/edit compatibility behavior;
- bounded Bash I/O, deadline, and process-tree termination;
- shared process custody extracted from Worker Kernel.

Still missing:

- remove `WorkerRuntime` from host dependency injection;
- move workspace/process claims to core `tron.sqlite` custody;
- teach `read` to page Engine result/resource references, not just paths;
- delete Worker compatibility host functions after cutover.

#### Clean-break archive and reset

Files:

- `src/app/legacy_archive.rs`
- `src/app/cli/mod.rs`
- `src/app/cli/tests.rs`
- `src/app/bootstrap/tests/cli.rs`

Implemented:

- hidden-independent `tron state archive-legacy` archive creation;
- exact archive manifest, SHA-256 verification, path/entry/size bounds, and
  owner-only publication;
- explicit `tron state cutover-minimal-core <archive> --archive-sha256 <digest> --confirm-reset`;
- crash-resumable pending/completed receipts;
- symlink-safe deletion of this exact whitelist:
  `internal/database`, `internal/terminal`, `internal/run`,
  `workspace/workers`, and `workspace/worker-state`;
- preservation of auth, settings, vaults, backups, ordinary workspaces, and
  future capability roots.

Six focused archive/reset tests passed before the later shared-tree edits. No
live profile was archived or reset.

#### Core coordination in `tron.sqlite`

Files:

- `src/domains/agent/coordination/{mod.rs,model.rs,tests.rs}`
- `src/domains/session/event_store/store/event_store/core_coordination.rs`
- `src/domains/session/event_store/store/event_store/core_coordination/*.rs`
- coordination additions in EventStore schema/module owners

Implemented at the store/service layer:

- stable agents and hidden transcripts;
- reusable FIFO assignments, attempts, immutable authority/resource snapshots,
  deadlines, and inline/blob result custody;
- atomic child + transcript + first-assignment admission;
- semantic messages and Engine-derived wake intents;
- atomic wait registration, terminal reconciliation, assignment parking,
  cycle rejection, and absorption of pending/leased individual wakes;
- discovery, inspect, assignment/message history;
- offer response, cancel, configure, close, retry, and promotion with
  idempotent management receipts;
- mutable management ownership separated from immutable spawn lineage;
- durable trace state, message/hop counters, autonomy pause evidence, and
  authenticated resume storage;
- additive repair for developer databases containing earlier dormant columns.

Earlier focused runs reported five coordination tests and eight primitive-
schema tests passing. Later management/provenance additions were not compiled
or re-run in the frozen combined tree.

Known coordination gaps:

- duplicate wake lookup/binding APIs collide with Agent Execution;
- paused traces are not yet excluded by every dispatch query;
- waiting assignments need an eligible wake before resumption;
- process-lease quiescence is absent from configure/close/promotion;
- directory discovery currently filters an in-memory full directory;
- autonomy pause Attention/invalidation delivery is not wired;
- management, migration, promotion, and autonomy regression coverage is
  incomplete;
- no provider/client action-union adapter exists.

#### Core Agent Execution

Files:

- `src/domains/agent/execution/{mod.rs,model.rs,messages.rs,service.rs,runner.rs}`
- `src/domains/session/event_store/store/event_store/core_execution.rs`
- causality/message-boundary changes in the existing agent loop/runtime

Drafted:

- one-second durable reconciliation plus notify fast path;
- startup interruption/wake-lease recovery;
- per-agent in-flight guard;
- separate active-recovery and queued-head lanes to avoid parked-work
  starvation;
- exact FIFO claim and attempt opening;
- ordinary persistent session loop reuse with assignment-only causality;
- safe-boundary `message.agent` materialization and observation;
- transcript-evidence terminalization and structured descendant join;
- assignment deadline/turn ceilings and immutable model/reasoning snapshots;
- result/wait wake message repair and idle auxiliary wake draft.

This slice is mid-integration and has no focused tests. It is not activated.
Important unresolved semantics include:

- exact wake trace/hop provenance is reconstructed/hardcoded in
  `execution/messages.rs` instead of using the persisted wake values;
- waiting assignments and unrelated actionable questions need distinct
  auxiliary versus resume paths;
- the auxiliary boundary can currently mistake pre-existing Waiting state for
  completion of its own run;
- boundary message queries page then filter and should instead filter in SQL;
- cancellation is not wired to process-local interruption;
- core trusted Team Context is absent; provider turns still call the
  Worker-owned Team Context hook;
- exact wake delivery-key ownership needs a fail-closed race test.

#### Persistent TypeScript/code substrate

Files:

- `src/domains/code_runtime/*.rs`
- hidden helper mode in `src/app/cli/mod.rs`
- canonical code tables in EventStore `current.sql`

Implemented:

- Oxc TypeScript validation/type stripping;
- capability-empty frozen QuickJS SDK;
- production evaluation in a disposable child process using the installed
  `tron code-runtime-helper` hidden mode, never PATH guessing;
- persistent lexical/top-level-await replay;
- durable cells, calls, events, idempotency conflict detection, and exact
  completed-call replay;
- cancellation/time/memory/stack/output/call limits;
- closed broker routing for agents, schedules, fixed services, skills, state,
  and file read/write/edit;
- paged summary-only skill discovery, separate inspect, root confinement,
  digest pinning, and project/profile shadowing;
- Engine-derived project-scoped skill state namespaces;
- SQLite authorizer and transactional mutation receipts;
- exactly four fixed-service interfaces with user-friendly descriptors;
- canonical schema ownership (the runtime verifies tables and does not create
  a private production schema).

The original 11 code-runtime tests passed before final broker/schema/helper
changes. Those final changes never received an unobstructed combined check.
Production child-process crash/cancel/effect-replay tests remain missing.

The critical blocker is a parked nested wait. Returning `{pending}` to
JavaScript is incorrect. Required design:

```text
CodeRunOutcome = Completed | Parked

CodeContinuationService::resume_for_assignment(
  assignment_id,
  transcript_session_id,
  causal_context,
  cancellation
) -> None
   | StillParked
   | Completed { cell_id, original_tool_invocation_id, result }
   | Failed { ... }
```

A parked code call must keep the cell and nested broker call nonterminal. Tool
phase must not append `ToolInvocationCompleted`, add a tool result, finalize
the Engine invocation receipt, or continue the provider. After a durable wake,
Agent Execution invokes code continuation before an ordinary provider call.
Completion binds exactly one result to the original provider invocation and
cell, then the normal provider loop resumes. Restart, cancellation, duplicate
wake, and effect-before-helper-crash all require regression tests.

Additional code cleanup:

- persist the original session/tool/Engine invocation and causal snapshot with
  a running cell;
- implement `AgentBrokerOperations` over the final CoordinationService;
- bound protocol frame allocation before `read_until` can grow past 4 MiB;
- prevent detached stderr cleanup on early skill-protocol exits;
- gate the old full-descriptor `SkillCatalog::discover()` and in-process
  evaluators to tests;
- add the exact single `code` contract only after continuation is complete.

#### Scheduling

Files:

- `src/domains/schedule/{mod.rs,contract.rs,recurrence.rs,service.rs,tests.rs}`
- `src/domains/session/event_store/sqlite/repositories/schedule.rs`
- `src/domains/session/event_store/store/event_store/schedules.rs`
- schedule tables/indexes in `current.sql`

Implemented and previously green:

- closed create/list/get/update/pause/resume/delete/run-now union;
- reusable-agent, fresh-agent, and namespaced capability targets;
- Engine-authored authority snapshots;
- one-time and bounded RFC 5545/IANA recurrence via `rrule = "0.14"`;
- DST, ambiguous/nonexistent local time, explicit-date/cardinality/scan bounds;
- CAS mutation, deterministic keys, skip/run-once/catch-up misfire,
  queue/skip overlap, transactional cursor + occurrence admission;
- durable occurrence leases/recovery, compact missed-window audit, tombstones;
- separate assignment/capability invocation binding;
- authenticated owner preauthorization which does not mutate before denial.

The schedule suite previously passed 14 tests and schema passed eight tests.
Still missing are lifecycle construction, the dispatcher tick, mapping due
occurrences into core assignments/fresh agents/capability invocations,
completion binding, the single model-facing `schedule` contract, and iOS
Automations projections.

## Exact frozen verification state

The following commands were run after all workstreams stopped editing:

```text
cargo check --manifest-path packages/agent/Cargo.toml --lib   FAIL (exit 101)
cargo fmt --all --manifest-path packages/agent/Cargo.toml -- --check   PASS
git diff --check   PASS
```

`cargo check` has one small merge cluster (11 diagnostics):

1. unused `ClaimedAssignment` import in `agent/execution/runner.rs`;
2. two `i64` -> `u64` baseline mismatches at runner lines approximately 128
   and 132;
3. one `u64` -> `i64` EventStore sequence mismatch at approximately line 482;
4. duplicate `core_wake_record` definitions in
   `core_coordination/messages.rs` and `core_execution.rs`;
5. duplicate `bind_core_wake_message` definitions in the same owners;
6. the duplicates cause three multiple-applicable-method errors and two
   follow-on type-inference errors.

Do not paper over this with arbitrary casts. EventStore event sequences are
currently `i64`; choose one end-to-end type or use checked conversions at the
domain boundary. Consolidate wake CRUD under coordination; if retaining the
execution-side implementation because of its stronger validation, move that
validation into the coordination owner rather than keeping duplicate inherent
methods.

The WIP tree was formatted after the pause solely to satisfy the normal commit
guard; no known compiler or behavioral issue was repaired as part of that
housekeeping step.

Earlier green results remain useful evidence for isolated foundations, but do
not certify the current combined checkout:

- full Rust CI and the iOS baseline were green at starting commit `53aafbdfa`;
- archive/reset focused tests: 6 passed;
- minimal host tests: 4 passed;
- original code-runtime tests: 11 passed;
- schedule tests: 14 passed; primitive schema tests: 8 passed;
- early core coordination tests: 5 passed.

## Recommended restart sequence

Resume in small, green commits. Do not combine Worker deletion with unfinished
continuation semantics.

### Checkpoint 1 — make dormant foundations green

1. Consolidate `core_wake_record` and `bind_core_wake_message` under the
   coordination owner.
2. Normalize/check event sequence conversions and remove the unused import.
3. Run `cargo check --lib`, `cargo test --lib --no-run`, coordination, schedule,
   code-runtime, host, archive, and schema suites.
4. Commit before changing behavior.

### Checkpoint 2 — complete code parking and assignment execution

1. Add typed code `Completed`/`Parked` outcomes and persist original invocation
   identity/causality.
2. Make tool phase leave parked code incomplete.
3. Add Agent Execution's pre-provider continuation hook.
4. Fix Waiting versus auxiliary actionable-wake semantics.
5. Consume persisted trace/hop fields exactly.
6. Add restart, duplicate-wake, exactly-once result, starvation, >200-message,
   safe-boundary, cancellation, and helper-crash regressions.
7. Add core Team Context, bounded to 32 entries.

### Checkpoint 3 — wire dormant core lifecycle without advertising tools

1. Construct Agent Execution and Schedule services from narrow registration
   dependencies.
2. Activate dispatcher/recovery tasks under the shutdown coordinator.
3. Wire admission notify and cancellation interruption.
4. Wire schedule occurrences to reusable/fresh agents and capability registry.
5. Inject production fixed-service owners.
6. Add end-to-end fake-provider restart tests while functions remain hidden.

### Checkpoint 4 — expose the exact eight tools atomically

1. Add closed `agent`, `code`, and `schedule` contracts/handlers with all
   identity, trace, authority, and idempotency fields Engine-derived.
2. Replace Worker-owned provider surface selection and Team Context.
3. Make `read` page result/resource references.
4. Add an exact-set assertion for all eight and ensure no conditional title or
   dynamic Worker tool can project.
5. Negotiate one complete minimal-core capability; never advertise a partial
   surface.

### Checkpoint 5 — remove Worker architecture

1. Move workspace/process claims, result/blob custody, notifications,
   transcription, browser control, and Mac control to their core/native owners.
2. Replace fixed compaction/title/continuity policies without dynamic hooks;
   delete Forge, Evaluator, General Delegate dependency, roles, role review,
   worker bundles, dynamic runners, routing, triggers, webhooks, and Worker
   invocation storage.
3. Remove Worker registration/lifecycle, `workers.sqlite`, dynamic tool
   projection, Worker compatibility aliases, and Worker source/docs/tests.
4. Rename residual internal `WorkerId`/`owner_worker` Engine catalog vocabulary
   to capability/function ownership only if it still has a real independent
   production purpose.

### Checkpoint 6 — iOS Runtime Hub and clean cutover

1. Preserve/adapt the existing Agents sheets to core projections.
2. Replace Worker Console and role review with Runtime Hub: Agents, Skills,
   Automations, Services, results, health, and read-only audit.
3. Remove `agent_role_review.v1` and all user-facing Worker terms.
4. Add capability negotiation, offline retained state, paging, invalidation,
   live transcript, schedule, skill, and fixed-service tests.
5. Exercise archive/reset only in an isolated disposable profile.
6. Run full Rust CI and both supported iOS simulator suites; use the `tron-ios`
   skill for simulator/device work. Never run `tron deploy`.

## Required acceptance matrix

At minimum, the final implementation must prove:

- spawn/send/wait/result idempotency across every commit/import/crash boundary;
- one stable agent/transcript across assignments and restart;
- FIFO reuse, offers, questions/answers, peer messaging, and cross-workspace
  communication without authority transfer;
- passive information never starts a run, while actionable work wakes only at
  safe boundaries;
- explicit all/any waits, completion-before-registration, unrelated temporary
  wakes, released targets, reply and assignment cycle rejection;
- automatic unwaited results and one coalesced waited result;
- structured descendant join, recursive cancellation, deadlines, turn limits,
  message/hop autonomy pause, and authenticated resume;
- 128 parked assignments cannot hide later queued work and irrelevant message
  pages cannot hide an active assignment message;
- code lexical/TLA replay, parked nested wait continuation, helper crash after
  external effect, exact effect replay, cancellation, resource bounds, and
  absence of ambient authority;
- skill progressive disclosure, digest pinning, shadow precedence, project
  namespace isolation, and authority non-expansion;
- schedule DST, misfire, overlap, restart, lease recovery, closed target, and
  exact authority snapshot behavior;
- shared-workspace write/process collision coordination, described honestly as
  coordination rather than sandboxing;
- clean archive verification, reset crash replay, preservation whitelist, and
  refusal of unsafe paths/digests;
- exact eight-tool provider surface and absence of Worker/role compatibility
  projection;
- cohesive iOS Runtime Hub, Agents, Skills, Automations, Services, result and
  transcript inspection on supported simulator/device configurations.

## Operational cautions for the next agent

- Read this file and the nearest `mod.rs` owners before editing.
- Inspect `git status` first; this checkpoint intentionally contains many
  untracked new source files.
- The frozen WIP is already rustfmt-clean; preserve the commit when comparing
  later semantic repairs.
- Do not expose dormant contracts to make tests easier.
- Do not add repo-managed first-party skills.
- Do not convert Worker bundles or user state heuristically.
- Do not run the clean-break reset on `~/.tron` or `~/.tron-dev`.
- Do not call `tron deploy`.
- Code, tests, and owner documentation must become green together before each
  subsequent checkpoint is committed.

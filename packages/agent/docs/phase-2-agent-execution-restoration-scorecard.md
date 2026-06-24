# Phase 2 Agent Execution Restoration Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**
Total weight: **100**

Planning branch: `codex/ios-affordance-restoration-map-current`
Planning baseline HEAD: `980867c3534612cd8d30867473a5b3eb36ad1f03`

Companion artifacts:

- [`phase-2-agent-execution-restoration-evidence-manifest.md`](phase-2-agent-execution-restoration-evidence-manifest.md)
- [`phase-2-agent-execution-restoration-inventory.md`](phase-2-agent-execution-restoration-inventory.md)
- [`phase-2-agent-execution-restoration-inventory.tsv`](phase-2-agent-execution-restoration-inventory.tsv)
- [`restoration-retrospective-audit-status.md`](restoration-retrospective-audit-status.md)

## Current Restoration Baseline

Discovery update: 2026-06-24.

Canonical plan file: this scorecard. The README names this file as the durable
Phase 2 plan, while the inventory and evidence manifest are companion
machine-readable and validation artifacts.

Current implementation baseline verified by this update:
`main@6ec2e03baf03bf260e8e1d3522c93ef8bdeb563f`
(`Fix git_commit HEAD drift guard`). That line includes accepted Slice 6A
read-only Git/worktree status and diff evidence, accepted Slice 6B index-only
stage/unstage, accepted Slice 6C staged-index commit evidence, and mainline
closeout documentation for Slice 6A and Slice 6B.

Closeout note: this update fast-forwarded `main` from current `origin/main` to
the accepted Slice 6C implementation stack, then records the independent review
and fix-loop evidence here and in the retrospective tracker.

Completed Phase 2 restoration slices at this baseline:

- Slice 0: planning artifacts and static entry gates;
- Slice 1: catalog discovery, inspect, and conformance evidence;
- Slice 2: approval/freshness evidence resources and fail-closed checks;
- Slice 3: memory foundation, redacted record custody, prompt traces, and
  migration envelopes;
- Slice 4: bounded filesystem agent toolbox with resource-backed previews,
  commits, patch evidence, and truncated-snapshot hardening;
- Slice 5A: durable jobs and process lifecycle foundation with accepted race
  hardening;
- Slice 6A: read-only Git/worktree status and bounded diff evidence;
- Slice 6B: index-only Git stage/unstage with resource and lifecycle evidence;
- Slice 6C: guarded staged-index Git commit evidence with resource and
  lifecycle evidence.

Current next action:
Independently review the **Slice 6D: Git Branch Start Foundation**
implementation candidate from fresh `origin/main`. Slice 6D is the local branch
create-and-switch boundary after accepted Slice 6C completed staged-index
commit creation. Branch deletion, rename, arbitrary checkout, detached-HEAD
commits, merge/rebase/reset, stash/clean, fetch/pull/push, PR handoff,
conflict resolution workflows, worktree graph resources, public API expansion,
production deployment behavior, and native SourceChanges UI remain deferred.

## Scope

This is a planning, handoff, and implementation-evidence artifact. It records
candidate branch work without making pre-acceptance claims. It does not by
itself restore agent-execution features, add public `/engine` methods, add
database migrations, add iOS product panels, add worker packages, or
reintroduce repo-managed first-party skills.

The plan converts Phase 1 deferrals and the BPRC restoration backlog into an
ordered Phase 2 roadmap. Future implementation threads must treat old modular
capability code as evidence, not as authority. Every restored capability must
enter through the current Worker / Function / Trigger model with explicit
resources, events, grants, replay evidence, tests, docs, and iOS parity
decisions.

## Source Baseline

Inspected planning sources:

- `AGENTS.md`
- `README.md`
- `packages/agent/docs/ios-affordance-restoration-map-scorecard.md`
- `packages/agent/docs/ios-affordance-restoration-map-inventory.md`
- `packages/agent/docs/ios-affordance-restoration-map-inventory.tsv`
- `packages/agent/docs/ios-affordance-restoration-progress.md`
- `packages/agent/docs/primitive-baseline-vs-modular-capability-engine-feature-index.md`
- `packages/agent/docs/baseline-pre-restoration-closure-inventory.md`
- `packages/agent/docs/baseline-pre-restoration-closure-inventory.tsv`
- `packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.md`
- `packages/agent/docs/self-updating-worker-runtime-foundation-inventory.md`
- `packages/agent/docs/security-authority-capability-boundaries-scorecard.md`
- `packages/agent/docs/security-authority-capability-boundaries-inventory.md`
- `packages/agent/docs/security-authority-capability-boundaries-evidence-manifest.md`
- `packages/agent/docs/concurrency-scheduling-discipline-scorecard.md`
- `packages/agent/docs/concurrency-scheduling-discipline-inventory.md`
- `packages/agent/docs/concurrency-scheduling-discipline-evidence-manifest.md`
- `packages/agent/docs/true-primitive-cleanup-scorecard.md`
- `packages/agent/docs/true-primitive-cleanup-evidence-manifest.md`
- `packages/agent/docs/hierarchical-rearchitecture-scorecard.md`
- `packages/agent/docs/hierarchical-rearchitecture-inventory.md`
- `packages/agent/docs/hierarchical-rearchitecture-evidence-manifest.md`
- `packages/agent/src/lib.rs`
- `packages/agent/src/domains/mod.rs`
- relevant domain `mod.rs` files for `agent`, `auth`, `blob`,
  `capability`, `filesystem`, `logs`, `message`, `model`, `registration`,
  `session`, `settings`, `system`, `transcription`, and
  `worker_lifecycle`
- `packages/ios-app/docs/architecture.md`

## Invariants

Legacy as evidence: old paths, old contracts, and old UI names are quarry
evidence. They do not authorize copying old domains, old DTOs, fixed iOS
panels, managed skill bundles, approval side channels, or hidden memory planes.

Minimal engine primitive: the engine primitive set stays small. Provider-facing
execution remains a single `execute` primitive unless a future scorecard proves
that widening the model surface is necessary. The engine owns substrate:
catalog, invocation, grants, streams, queues, triggers, resources, ledger,
replay, event storage, and external-worker protocol.

Modular capability package: product behavior returns as worker-owned functions,
triggers, resources, and events. A capability package owns schemas, authority,
storage, retention, rollback, conformance, tests, and docs. iOS renders generic
runtime surfaces first and receives a fixed native surface only when a stable
platform workflow justifies it.

Authority boundary: public `/engine` clients never mint authority scopes,
runtime metadata, file roots, worker identity, or secrets. Model-launched work
uses derived least-privilege grants and trusted runtime metadata.

Scheduling boundary: any queue, task, worker, background run, stream, or
long-running process must name an owner, capacity/backpressure, cancellation,
deadline/fairness policy, replay evidence, and shutdown behavior.

Memory boundary: memory is critical but must be hot-swappable. The engine may
own memory contracts, provenance, resource custody, privacy policy, and audit
events; memory algorithms, embeddings, retrieval engines, summarizers, ranking
models, and storage layouts are replaceable packages.

## Exhaustive Feature Coverage

The Phase 2 inventory covers every Phase 1 deferral and all 24 BPRC backlog
buckets:

- capability discovery, catalog search, routing, intent resolution, schema
  repair, conformance, and generated capability evidence;
- filesystem read, write, search, glob, find, diff, edit, patch, path
  authority, sandboxing, previews, and rollback evidence;
- jobs, processes, shells, PTY-like sessions, long-running tasks, cancellation,
  output logs, leases, resource accounting, and bounded retention;
- worker lifecycle, self-extension, package proposal, installation, launch,
  stop, update, retirement, resource leases, runtime surfaces, and conformance;
- subagents, delegation, worker launching, parent-child causality,
  cancellation, result resources, and UI projection;
- goals, queues, questions, task planning, user approvals, inboxes,
  notifications, and real event backing;
- approval, safety, freshness, expiry, requester, scope, evidence, and
  authority-decision resources;
- web, research, browse, fetch, search, source provenance, network authority,
  cache policy, and redaction;
- git, worktrees, source control, branch/diff/stage/commit/merge/rebase/push,
  conflicts, PR handoff, and rollback;
- skills, rules, hooks, memory, artifact store, procedural state, evals, and
  loading policy;
- MCP, tool sources, plugin/source identity, sandbox policy, schema provenance,
  and conformance gates;
- scheduling, reminders, automations, monitors, background work, missed-run
  behavior, and cancellation;
- code interpreter and program execution through isolated workers with
  deterministic I/O envelopes and resource limits;
- database, events, settings, dependencies, migrations, retention, replay,
  profile parity, and dependency restoration;
- model/provider reasoning traces, thought/status streaming, hidden-reasoning
  metadata, capability evidence rendering, and truthful iOS display;
- APNs, device notification capability, per-device token lifecycle, device
  broker state, app badge semantics, and backend-event-dependent delivery;
- media, voice notes, persistent uploads, local/server transcription
  boundaries, artifacts, imports, repository trees, session history graphs,
  and system update diagnostics.

## Primitive And Capability Architecture

True primitives retained or added only with proof:

- provider loop and single model-visible `execute` tool;
- engine envelope, invocation ledger, idempotency, streams, queues, triggers,
  resource kernel, authority grants, resource leases, compensation records,
  replay manifest, event store, and external-worker socket protocol;
- narrow host-owned package lifecycle primitives already present in
  `worker_lifecycle`, kept separate from `/engine/workers`;
- memory contract/resource/event primitives described below, without binding
  Tron to a particular memory engine.

Modular capability packages:

- catalog/discovery package;
- filesystem package;
- job/process/program package;
- git/worktree package;
- web/research package;
- memory engine packages;
- skill/rule/hook/procedural packages;
- MCP/tool-source packages;
- scheduler/automation package;
- notification/device package;
- media/import/history packages;
- subagent/goal/question package.

iOS surface classes:

- generic runtime surface for new module state by default;
- server-fact rendering for current facts such as catalog rows, resource
  status, logs, traces, replay, and worker lifecycle;
- native stable platform surfaces only for high-frequency user workflows such
  as approvals, questions, file picking/review, source-control review,
  notification inbox, and memory audit after server contracts exist;
- iOS-only local surfaces only for device-local workflow state such as recent
  input reuse or local diagnostics;
- reject candidates for old panels that imply fixed product truth or hidden
  backend state without a module owner.

## Deep Memory Architecture

### Minimal Memory Primitives

The engine should own these memory primitives and no particular memory
implementation:

- `memory_engine` resource type: installed engine identity, version, package
  provenance, supported stores, privacy features, eval profile, and status;
- `memory_record` resource type: canonical memory item with subject, scope,
  body ref, provenance, confidence, author, source event refs, sensitivity,
  expiry, retention class, tombstone state, and migration lineage;
- `memory_index` resource type: engine-owned index metadata, not the index
  algorithm itself;
- `memory_decision` event/resource: retain, retrieve, redact, edit, delete,
  expire, migrate, disable, compare, and reject decisions with evidence;
- `memory_query` trace: bounded retrieval request, filters, engine, selected
  records, confidence/ranking metadata, redactions, and prompt inclusion
  reason;
- `memory_eval_run` resource: scored retrieval/retention/regression eval
  result with dataset provenance and engine version;
- `memory_policy` profile/resource: user/project/session scopes, privacy
  class, default retention, allowed engines, and disabled stores.

These primitives are engine-owned because they define custody, audit, privacy,
and context inclusion. The engine must not own embeddings, rerankers, vector
schema internals, summary algorithms, or proprietary memory layouts.

### Hot-Swappable Memory Engine Contract

Every memory engine package must expose a contract equivalent to:

- `memory_engine::inspect`: describe capabilities, stores, version, package
  provenance, privacy features, and migration support;
- `memory_engine::retain`: propose or apply a memory record from a typed
  source, returning provenance, confidence, redaction, and resource refs;
- `memory_engine::retrieve`: return bounded candidate records with scores,
  reasons, sensitivity, expiry, and prompt-inclusion recommendations;
- `memory_engine::edit`: edit a record by creating a versioned replacement;
- `memory_engine::delete`: tombstone or erase according to retention class;
- `memory_engine::expire`: apply expiry/retention policy;
- `memory_engine::migrate_export`: export portable records and index metadata;
- `memory_engine::migrate_import`: import portable records with validation and
  lineage preservation;
- `memory_engine::evaluate`: run retrieval/retention/procedural evals;
- `memory_engine::compare`: run A/B retrieval or shadow-retention comparison
  without changing active prompt context;
- `memory_engine::disable`: stop inclusion and optionally freeze writes while
  preserving audit records.

The contract must support engine swapping, disabling, shadow mode, side-by-side
comparison, and rollback. Active memory engine choice is profile-backed and
visible in iOS settings. A disabled engine must leave context assembly with a
clear "memory disabled" fact, not silently fall back to hidden behavior.

### Memory Store Families

Session memory:
short-lived facts and decisions scoped to one session, derived from session
events and trace records. It supports context continuity, pending decisions,
and local repair without becoming durable user memory automatically.

Durable user/project memory:
user-approved or policy-approved records scoped to user, project, workspace, or
repository. It carries edit/delete/export controls and conservative prompt
inclusion.

Semantic/vector memory:
replaceable retrieval index over portable `memory_record` resources. Engines
may use embeddings, keyword search, hybrid retrieval, rerankers, or local
models. The index is disposable because canonical records live in resources.

Episodic trace memory:
references session events, trace records, provider audit summaries, decisions,
errors, and outcomes. It answers "what happened" without rehydrating hidden
chain-of-thought.

Procedural skill/rule memory:
agent-authored procedures, rules, hooks, and skills with provenance, evals,
activation policy, and rollback. This is not repo-managed first-party skill
copying; it is learned or installed state under the same resource and eval
contract.

Artifact-backed memory:
large files, generated reports, diffs, code, screenshots, research packets, and
rendered outputs stored as artifacts/resources. Memory records reference these
artifacts by stable hash and preview, not by embedding full payloads into
prompt context.

### Privacy, Governance, And Evaluation

Memory packages must implement:

- redaction before durable write, retrieval, eval export, logs, and iOS display;
- sensitivity classification and user-visible reason for retention;
- provenance from source event/resource/trace, actor, tool, and timestamp;
- confidence scores with reason codes and downgrade paths;
- expiry, retention windows, tombstones, erasure, export, and migration;
- user/project scope boundaries, workspace isolation, and session-only mode;
- conflict handling, duplicate detection, replacement lineage, and rollback;
- eval suites for retention precision, retrieval relevance, privacy leakage,
  stale fact expiry, deletion obedience, prompt inclusion quality, and engine
  migration correctness;
- static guards against hidden hardcoded memory behavior in prompt assembly,
  repo-managed skill/rule directories, provider prompts, iOS local defaults, or
  unowned storage tables.

iOS must provide memory audit surfaces after the backend contract exists:

- active memory engine status and disabled/shadow mode;
- records by scope with provenance, confidence, expiry, sensitivity, and source
  refs;
- edit/delete/export/migrate controls gated by server authority;
- retrieval trace views for why a record entered context;
- A/B comparison summaries for engine swaps;
- privacy warnings and redaction previews before applying broad retention.

## Ordered Slice Roadmap

Each future implementation thread must present the handoff packet in this
scorecard before coding. Slices may split further, but they should not merge
without a fresh scorecard update.

### Slice 0: Phase 2 Entry Gates

Objective: install the Phase 2 planning artifacts, inventory, and static
classification updates.

User-facing outcome: none beyond durable docs; no restored feature.

True primitives: none added.

Modular boundaries: plan only.

Likely files/areas: `packages/agent/docs`, README, iOS architecture docs, and
static inventory rows.

Old evidence paths: IARM progress Phase 2 reminder, IARM TSV Phase 2 rows,
BPRC backlog rows, feature index.

Acceptance criteria: plan artifacts exist, source-backed scope is complete,
TSV has one row per feature family, and validations in the evidence manifest
pass.

Focused tests: personal-info guard, whitespace check, ignored-file audit, IARM,
BPRC, SSARR, SACB, PCC, TPC, HRA, DESI invariant targets as touched by the
planning artifacts.

iOS validation: none; no Swift UI changes.

Docs/static updates: this artifact set, README, iOS architecture, predecessor
inventory classifications.

User decisions: approve Slice 1 as the first implementation slice.

### Slice 1: Catalog, Discovery, And Capability Evidence

Objective: restore module/capability discovery without widening the
provider-visible tool list.

User-facing outcome: users and agents can inspect available workers/functions,
capability metadata, schemas, conformance, health, and generated UI resources.

True primitives: existing catalog, resource, stream, grant, and replay
substrate.

Modular boundaries: `catalog_discovery` worker/package owns search, inspect,
intent metadata, schema repair hints, conformance status, and evidence
resources. It does not run capability side effects.

Likely files/areas: `packages/agent/src/engine/catalog`,
`packages/agent/src/engine/durability/resources`, `packages/agent/src/domains`,
`packages/ios-app/Sources/UI/AgentCockpit`,
`packages/ios-app/Sources/UI/RuntimeSurfaces`,
`packages/ios-app/Sources/Engine/Protocol/Catalog`.

Old evidence paths: `BPRC-FEATURE-01`, `IARM-SURFACE-005`,
`IARM-SURFACE-007`, `IARM-SURFACE-008`,
`primitive-baseline-vs-modular-capability-engine-feature-index.md` section 1.

Acceptance criteria: catalog facts are resource-backed, hidden/internal/admin
functions remain protected, conformance evidence is durable, replay includes
discovery decisions, iOS renders generic catalog/resource facts truthfully, and
provider-visible `execute` remains singular.

Focused tests: catalog visibility, schema canonicalization, conformance
resource creation, replay manifest inclusion, iOS catalog DTO decoding, cockpit
projection tests, SACB direct-invocation guards.

iOS validation: simulator screenshots for generic catalog/resource rendering
if UI changes.

Docs/static updates: README capabilities, domain docs, BPRC/IARM successor
inventory rows, SACB/TPC/HRA rows for new source.

User decisions: whether to expose discovery in chat, Runtime Cockpit, Settings,
or only generated surfaces for the first cut.

### Slice 2: Authority, Approval, Safety, And Freshness

Objective: add durable approval/freshness decisions before riskier tools return.

User-facing outcome: when the agent needs permission, the user sees a scoped
request with evidence, expiry, consequences, and approve/deny choices.

True primitives: authority grants, decision resources, streams, ledger, replay,
and iOS notification-attention hooks.

Modular boundaries: approval worker owns request/decision resources. Tool
packages depend on this worker instead of implementing private prompt/approval
side channels.

Likely files/areas: `engine/authority`, `engine/durability/resources`,
`domains/registration`, `packages/ios-app/Sources/Engine/Protocol/Interaction`,
future `UI/Approvals` only after contract proof.

Old evidence paths: `BPRC-FEATURE-09`, `IARM-SURFACE-023`.

Acceptance criteria: decisions have requester, scope, risk, expiry, evidence,
resource selectors, trace refs, replay refs, and denial behavior. Expired or
missing decisions fail closed.

Focused tests: grant derivation, approval expiry, replay, denial, idempotency,
iOS decode/view model, and SourceGuard absence of fake local approvals.

iOS validation: simulator and Computer Use validation for approval sheets if a
native surface is added.

Docs/static updates: README authority, events, DB/resources, iOS architecture,
SACB inventory.

User decisions: risk classes requiring explicit approval, default expiry, and
whether approval notifications can interrupt chat.

### Slice 3: Memory Foundation And Engine Contract

Objective: define and implement the hot-swappable memory contract and resource
custody before specialized memory engines.

User-facing outcome: users can see memory is disabled, active, shadowed, or
using a chosen engine; they can audit retained records and disable memory.

True primitives: memory resource/event contract, engine-selection policy,
prompt-inclusion trace, eval-run resource, and migration envelope.

Modular boundaries: memory engines are packages behind the memory contract.
The first engine may be a simple deterministic local resource engine; vector or
semantic engines arrive later under the same contract.

Likely files/areas: `engine/durability/resources`,
`domains/agent/context`, `domains/capability/operations`,
`shared/protocol/memory`, `domains/memory`, README and memory/static
inventories. Slice 3 does not add profile settings or native iOS controls;
memory policy is resource-backed and iOS remains on generic resource/runtime
facts until a workflow proves native settings/audit UI is needed.

Old evidence paths: `BPRC-FEATURE-10`, `IARM-SURFACE-034`,
feature index section 10.

Acceptance criteria: no hidden prompt memory; records carry provenance,
confidence, expiry, sensitivity, edit/delete/export/migration state; disabled
mode is explicit; prompt inclusion is traceable; swap/shadow mode is possible.

Focused tests: memory contract schema, record lifecycle, prompt inclusion trace,
redaction, deletion, disabled mode, migration export/import, provider-safe
context audit, resource-backed output contracts, personal-info guard, SSARR
successor guard.

iOS validation: no native iOS UI lands in the foundation slice; generic
resource/runtime rendering remains the client path.

Docs/static updates: README context/settings/database, iOS architecture, memory
inventory, SSARR allowlist, source guards.

User decisions: default memory off/on, initial engine, retention defaults,
privacy classes, and whether any automatic retention is allowed.

### Slice 4: Filesystem Capability Package

Objective: restore bounded filesystem tools beyond the workspace selector.

User-facing outcome: the agent can read, write, search, diff, edit, and propose
patches under authorized roots with previews and rollback evidence.

True primitives: existing `execute` file primitives, authority roots, resource
records, replay, and trace files.

Modular boundaries: filesystem package owns `read`, `write`, `find`, `glob`,
`search_text`, `diff`, `edit`, `apply_patch`, previews, and materialized
outputs. Current workspace-browser domain remains UI picker only.

Likely files/areas: `domains/filesystem`, `domains/capability/operations`,
`engine/authority/grants/paths.rs`, resource kernel, iOS generic result
rendering.

Old evidence paths: `BPRC-FEATURE-02`, `IARM-SURFACE-035`,
feature index section 2.

Acceptance criteria: canonical path containment, preview before destructive
changes, patch/diff resources, rollback strategy, no network authority, output
limits, replay hashes, and no broadened workspace picker behavior.

Focused tests: path traversal, symlink/canonical root, patch validation, diff
hashes, large file bounds, rollback, SACB execute guards, iOS generated-result
rendering.

iOS validation: screenshots only if native file preview is added; otherwise
generic result surface tests.

Docs/static updates: README capabilities/database, filesystem domain docs,
IARM progress deferral note.

User decisions: when writes require approval, whether destructive patches need
native review, and default file size limits.

### Slice 5: Jobs, Processes, Shells, And Program Execution

Objective: separate synchronous primitive `process_run` from durable
long-running jobs and code interpreters.

User-facing outcome: users can see running commands, logs, cancellation, exit
state, artifacts, and resource limits.

True primitives: queue, stream, lease, resource, trace, log, replay, and
authority substrates.

Modular boundaries: job/process package owns background jobs, shell sessions,
PTY-like behavior if approved, cancellation, logs, output materialization, and
program execution workers. Embedded runtimes are isolated packages, not engine
internals.

Likely files/areas: `engine/durability/queue`, `engine/durability/streams`,
`engine/durability/resources`, future `domains/jobs`, future external worker
packages, iOS process/job surfaces only after protocol stability.

Old evidence paths: `BPRC-FEATURE-03`, `BPRC-FEATURE-15`,
`IARM-SURFACE-024`, feature index sections 3 and 15.

Acceptance criteria: bounded output, cancellation, timeout, dead-letter or
terminal state, replayable logs, no-network or declared-network policy,
deterministic I/O envelope for program execution, and explicit retention.

Focused tests: queue lifecycle, cancellation, stream replay, log retention,
lease expiry, shutdown, process sandbox, interpreter isolation, CSD inventory.

iOS validation: simulator/Computer Use for any native job detail or cancel UI.

Docs/static updates: README capabilities/database/events, CSD/PERF/SACB rows,
dependency review for `portable-pty` or runtime engines if introduced.

User decisions: PTY support, interpreter languages, network policy, output
retention, and approval rules.

#### Selected Slice 5A Discovery Packet

Exact next slice to implement: **Slice 5A: Durable Jobs And Process Lifecycle
Foundation**.

Why this slice is foundational: the current engine already has queue, stream,
resource, lease, trace, replay, and bounded `process_run` substrates, but there
is no package-owned durable job object that users or agents can inspect,
cancel, replay, or cite. Without this slice, later git, web, source import,
subagent, scheduler, notification, and program-execution work would either
block on synchronous `process_run` or reintroduce private subprocess loops,
hidden log stores, and inconsistent cancellation semantics.

Core versus modular split:

- Core/harness: reuse the existing engine queue, stream, resource, lease,
  authority-grant, trace, replay, and output-contract primitives. Add to the
  engine only if the jobs package exposes a missing generic primitive needed by
  multiple package families, and prefer using existing `RegisterResourceType`,
  stream publication, queue receipt, and lease APIs.
- Modular package: create a jobs/process package that owns job resource types,
  command start/status/list/log/cancel operations, bounded output
  materialization, terminal-state transitions, lifecycle stream payloads,
  shutdown cleanup, resource retention, and package docs/tests.
- Synchronous primitive boundary: keep `process_run` as the short, bounded,
  `networkPolicy: none` command operation. Durable work enters the jobs package
  through model-facing `execute` operation values backed by package functions;
  it does not widen the provider-visible tool surface.
- Program execution boundary: define only the lifecycle envelope needed for a
  future interpreter worker if it naturally falls out of the job model. Do not
  add language runtimes, embedded JavaScript/Python execution, dependency
  bundles, notebooks, or package-specific interpreter sandboxes in Slice 5A.
- iOS boundary: use generic runtime/resource rendering first. Native process
  lists, log viewers, and cancel controls require a later server-contract and
  UX approval pass.

Implementation constraints:

- Every job must have an owner, session/workspace scope, authority grant,
  working directory provenance, network policy, resource limits, timeout,
  cancellation path, terminal state, replay refs, and retention class.
- Default network policy is `none`; jobs that cannot prove network denial fail
  closed. Network-enabled jobs wait for a later web/network authority slice.
- Command output is bounded. Large stdout/stderr bodies must become
  resource/blob-backed artifacts with hashes and previews rather than unbounded
  inline payloads.
- Cancellation must be durable and terminal from the receipt perspective: a
  late process result cannot resurrect or complete a cancelled job.
- Shutdown must either terminate owned child processes or record an
  inspectable orphan/unknown terminal state; silent background processes are
  not allowed.
- Mutating command starts require idempotency; replay must not rerun completed
  commands unless the caller supplies a new idempotency key and authority.
- Approval integration is by contract only in this slice: expose the risk and
  evidence hooks needed for later policy, but do not choose package-wide risky
  approval defaults.
- No broad dependency restoration. `portable-pty`, interpreter engines, or
  runtime bundles require a separate dependency/security review before use.

Risks and design questions resolved for Slice 5A:

- PTY/TUI support is deferred; durable non-interactive jobs come first.
- Interpreter languages are deferred; the first useful primitive is lifecycle,
  not a language runtime.
- Network is denied by default; web/research must not be smuggled through job
  commands.
- Native iOS process UI is deferred; generic runtime/resource facts are enough
  for the foundation slice.
- Existing `process_run` stays available for short bounded commands and should
  not be rewritten into a durable job system as part of this slice.

Required tests and verification:

- Focused Rust tests for job start/status/list/log/cancel, timeout,
  terminal-state idempotency, bounded stdout/stderr, artifact/resource hashes,
  lifecycle stream replay, queue receipt linkage, lease expiry, shutdown
  behavior, and late-result-after-cancel denial.
- Authority tests for trusted working-directory metadata, `networkPolicy: none`
  enforcement, derived grant requirements, approval evidence hooks, and denial
  when sandboxing is unavailable.
- Resource/schema tests for job resource definitions, output contracts,
  lifecycle payloads, retention fields, and replay/evidence refs.
- Static/invariant coverage: CSD for owner/backpressure/cancellation/shutdown,
  SACB for authority/network/process boundaries, TMB for package/engine
  separation, HRA/PCC/TPC for file ownership and line budgets, BPRC/IARM for
  deferral classification, DESI for scorecard/evidence consistency, personal
  info guard, and `git diff --check`.
- iOS verification only if generic runtime rendering changes; no native Swift
  UI is expected in Slice 5A.

Explicit non-goals:

- no PTY shell sessions, persistent interactive terminal, or terminal emulator;
- no embedded code interpreter, notebook, JavaScript/Python runtime, package
  manager, or dependency restoration;
- no web/search/fetch/browser/network research behavior;
- no git/worktree/source-control workflows;
- no subagents, goals, questions, scheduler, APNs, notification inbox, or
  native iOS process panel;
- no production deployment behavior and no `tron deploy`;
- no hidden subprocess daemons, private log stores, or package-specific
  cancellation mechanisms outside the shared job lifecycle.

Likely implementation files/domains to inspect or touch:

- `packages/agent/src/domains/capability/operations/process.rs` and
  `packages/agent/src/domains/capability/operations/mod.rs`;
- future `packages/agent/src/domains/jobs/{mod.rs,contract.rs,handlers.rs,service.rs,types.rs,schema_tests.rs,tests.rs}`;
- `packages/agent/src/domains/mod.rs` and startup registration wiring;
- `packages/agent/src/engine/durability/queue/`,
  `packages/agent/src/engine/durability/streams/`,
  `packages/agent/src/engine/durability/resources/`, and
  `packages/agent/src/engine/authority/leases.rs`;
- `packages/agent/src/engine/authority/grants/authorization.rs` for
  operation-to-scope/network policy checks;
- provider prompt/schema documentation in
  `packages/agent/src/domains/model/providers/openai/message_converter/mod.rs`;
- focused/static tests under `packages/agent/tests/`, especially CSD, SACB,
  TMB, HRA, PCC, TPC, BPRC, IARM, DESI, and primitive trace execution;
- README capability, event, database/resource, testing, and progressive
  disclosure sections plus the new jobs domain `mod.rs` docs.

#### Slice 5A Implementation Status

Status: **implemented on branch `codex/phase-2-jobs-process-lifecycle-current`
and accepted on current consolidated `main`**.

Shipped behavior:

- Added `packages/agent/src/domains/jobs/` as the modular owner for durable
  non-interactive local process jobs. The domain owns `jobs::start`,
  `jobs::status`, `jobs::list`, `jobs::log`, `jobs::cancel`, and
  `jobs::cleanup` contracts, handler bindings, resource lifecycle service,
  bounded process runtime, schemas, and focused tests.
- Added the built-in `job_process` resource kind
  (`tron.resource.job_process.v1`) with running/completed/failed/timed_out/
  cancelled/archived lifecycle states. Job records include command identity,
  trusted working-directory provenance, authority grant/scopes, limits,
  cancellation metadata, terminal state, bounded output refs, trace refs,
  replay refs, retention hints, and revision.
- Job finalization creates bounded `execution_output` resources and links them
  from the job with `produced_output`. Output previews are capped by
  `maxOutputBytes`; terminal records retain exit code/timed-out/cancelled/error
  evidence without storing unbounded stdout/stderr inline.
- Provider-visible access remains the single `capability::execute` tool via
  `job_start`, `job_status`, `job_list`, `job_log`, and `job_cancel`
  operation values. `jobs::cleanup` is a direct domain maintenance capability,
  not a model/provider operation.
- `process_run` remains the short synchronous bounded command primitive.
  Durable lifecycle is separate package state over existing authority,
  resources, streams, traces, replay, idempotency, and output contracts.
- `job_start` and `job_cancel` require idempotency at the provider boundary.
  All provider-visible job operations require current-session context.
  `job_start` requires trusted working-directory metadata and an active
  authority grant with `networkPolicy: none`; if the platform cannot enforce
  network denial, job start fails closed.
- Jobs run in an owned process group on supported Unix/macOS hosts. Timeout,
  cancel, and shutdown paths signal that group and bound stdout/stderr draining
  to the same lifecycle deadline so descendants that inherit output pipes
  cannot keep a job running indefinitely.
- Cancellation first asks the runtime to signal a live process group. The
  resource records non-terminal cancellation-request metadata, and runtime
  finalization writes terminal `cancelled` with bounded output evidence after
  process cleanup. Late cancel requests against already-completed jobs return
  completion-pending/already-terminal status instead of overwriting completion
  and dropping output evidence.
- If cancellation-request metadata lands between finalization's resource read
  and terminal update, finalization treats the resource-store version conflict
  as a retryable jobs-domain race: it reloads the current nonterminal job,
  preserves cancellation metadata, and retries the terminal update using the
  already-created output resource/link.
- Re-audit follow-up for Order 20/Slice 5A reconciles stale pre-startup
  `running` job records even when more than 500 newer live or post-startup rows
  fill the public newest-first list page. Startup/list/cleanup use an internal
  scoped scan, and targeted status/log/cancel rechecks only the addressed scoped
  resource before returning it.
- Domain shutdown requests cancellation for running process groups through the
  existing shutdown coordinator when present. Terminal cleanup archives scoped
  terminal jobs by retention criteria.

Core/modular split as implemented:

- Core additions were limited to one generic resource type definition and
  existing authority helpers that recognize direct `jobs::` functions and
  require trusted working-directory metadata for `job_start`.
- The jobs package owns process runtime handles, lifecycle state transitions,
  bounded output capture, stream payloads, cleanup, and tests. No filesystem,
  git, web, subagent, scheduler, memory, iOS, provider, auth, settings, or DB
  internals know jobs implementation details.
- Queue integration was **not** added in Slice 5A. The implementation found
  that queuing an internal jobs runner from model-launched `execute` would
  require broadening derived grants or adding hidden worker targets. That is a
  separate design problem and is deferred until a queued-internal-grant model
  is explicitly approved.

Remaining non-goals after Slice 5A and accepted Slices 6A/6B/6C:
PTY/interactive terminal,
interpreter or runtime package, git/worktree/source-control behavior beyond
read-only status/diff, index-only stage/unstage, and staged-index commit,
web/network behavior, subagents, scheduling, native iOS process panels, and
production deployment behavior.

### Slice 6: Git And Worktree Foundations

Objective: restore source-control workflows over durable worktree resources.
Slice 6A begins with accepted read-only repository observation; Slice 6B accepts
index-only stage/unstage; later accepted sub-slices own higher-risk source
control workflows.

Accepted user-facing outcome: Slice 6A lets users inspect branch status,
detached HEAD state, upstream/ahead-behind, dirty summaries, and bounded
staged/unstaged diff evidence. Slice 6B adds explicit index-only stage/unstage
for relative paths after expected HEAD, reason, idempotency, and conflict
checks. Slice 6C adds guarded staged-index commit evidence. Later sub-slices
may add branch starts, conflict workflows, merges, rebases, pushes, and PR
handoff with evidence after separate approval.

True primitives: filesystem package, jobs package, resource graph, authority,
replay, trace, and approval decisions.

Modular boundaries: the git/worktree package owns repo facts and Git command
execution. Slice 6A adds a narrow read-only `domains/git` boundary with
`git::status` and `git::diff` backend contracts plus provider-visible
`git_status` and `git_diff` execute operations. Slice 6B adds only
`git::stage`/`git::unstage` backend contracts plus provider-visible
`git_stage`/`git_unstage` operation values. It does not hide worktree state
inside sessions or iOS caches.

Current files/areas: `packages/agent/src/domains/git/`,
`packages/agent/src/domains/capability/operations/git.rs`,
`packages/agent/src/engine/durability/resources/git_definitions.rs`, provider
execute schema text, startup registration, docs, and deterministic Rust tests.
Future areas: `domains/worktree`, branch/PR resources, conflict workflows, and
iOS SourceChanges only after a stable higher-level source-control contract.

Old evidence paths: `BPRC-FEATURE-05`, `BPRC-FEATURE-16`,
`IARM-SURFACE-025`, `IARM-SURFACE-029`, feature index sections 5 and 16.

Slice 6A acceptance criteria: Slice 6A covers trusted-path repo detection,
branch or detached HEAD identity, upstream/ahead-behind,
dirty/staged/unstaged/untracked summaries, bounded/truncated status and diff
evidence, non-repo and out-of-root rejection, textconv suppression for diff
evidence, and no implicit production deployment path. Slice 6B acceptance
criteria cover explicit index-only stage/unstage, expected HEAD freshness,
reason/idempotency requirements, absolute/traversal/missing path rejection,
nested-repository misuse rejection, conflicted pathspec rejection, bounded
before/after evidence, `git_index_change` resources, `git.lifecycle` stream
events, idempotency replay, and static guards admitting no other Git mutation
operation names. Later sub-slices own worktree acquisition/release, commit
evidence beyond accepted Slice 6C, rollback, push/PR approval, conflict
resources, and native iOS review.

Implemented sub-slice: **Slice 6B: Git Index Mutation Foundation**.
It adds `git_stage` and `git_unstage` operation values behind
`capability::execute`, backed by `git::stage` and `git::unstage` domain
contracts. The slice mutates only the Git index for explicit relative paths
inside the trusted working-directory repository. It requires caller idempotency,
a mutation reason, and an expected HEAD precondition, rejects
absolute/traversal/worktree-root escape, rejects conflicted pathspecs, preserves
the no-network/no-production-deploy boundary, and emits bounded before/after
status and diff evidence. The package creates a `git_index_change` resource and
publishes a `git.lifecycle` stream event for each committed stage/unstage.
Approval is not a hidden permission source: commit/push/PR approval checks are
deferred until those higher-risk operations exist.

Slice 6B non-goals: commits, commit-message policy, branch creation/checkout/
deletion, merge, rebase, reset, stash, clean, push/fetch/pull, PR handoff,
conflict resolution, worktree graph acquisition/release, repo import/tree
visualization, public `/engine` API expansion, production deployment behavior,
and native iOS SourceChanges UI.

Focused tests: clean repo, staged/unstaged/untracked dirty state, detached
HEAD, missing upstream, upstream ahead/behind, nested paths, non-repo paths,
trusted-root escape rejection, bounded/truncated status and diff output, and
schema guards proving only the accepted Git operation names are exposed.

Slice 6B focused tests: stage tracked edits, unstage staged paths, replay stage
with the same idempotency key, reject conflicted paths, reject
missing/absolute/traversal paths, reject worktree-root escapes, reject stale
expected HEAD values, reject non-repo/nested-repo misuse, require explicit
idempotency/reason through the provider boundary, verify `git_index_change`
resource refs and `git.lifecycle` stream evidence, verify bounded before/after
evidence, and update static guards so only `git_stage` and `git_unstage` are
newly admitted mutating Git operations.

#### Selected Slice 6C Discovery Packet

Exact next slice to implement: **Slice 6C: Git Commit Evidence Foundation**.

Why this slice is next: accepted Slice 6B can prepare the Git index but still
cannot turn reviewed staged changes into durable repository history. A staged
index commit is the smallest coherent follow-up because it completes the local
source-control loop without introducing branch management, conflict
resolution, remote network behavior, PR handoff, worktree graph resources, or
native iOS UI.

Core versus modular split:

- Core/harness: reuse the existing `capability::execute` primitive, authority
  grants, idempotency ledger, resource kernel, stream substrate, trace/replay
  refs, and bounded Git command helpers. Add only generic resource definition
  constants/schema wiring needed for a new `git_commit` evidence resource.
- Modular package: keep behavior in `domains/git`. Add backend commit service
  code and provider-visible `git_commit` operation value through
  `capability::execute`; do not add a direct `git::commit` catalog function,
  second model-facing tool, or public `/engine` API.
- Mutation boundary: `git_commit` may create exactly one commit from the
  already-staged index and advance the current named branch from
  `expectedHead` to the new commit only after proving symbolic `HEAD` still
  names that branch at the ref-update boundary. It must not auto-stage files,
  edit worktree content, checkout/create/delete branches, merge, rebase, reset,
  stash, clean, fetch, pull, push, or create PRs.
- Freshness boundary: `git_commit` must require both `expectedHead` and an
  expected staged index tree value. The slice should expose the staged index
  tree in existing read evidence, such as `git_status` or `git_diff`, before
  requiring it for commits. This prevents committing a staged set that changed
  after review even when HEAD is unchanged.
- Branch boundary: require a named branch and reject detached HEAD in Slice 6C.
  Detached commit support waits for an explicit worktree/branch policy slice.
- Hook/network boundary: commit execution must be non-interactive and must not
  run repository hooks, editors, pagers, credential prompts, GPG signing, or
  network-dependent helpers. The operation should use command/env/config
  controls that make those exclusions deterministic and covered by tests where
  practical.

Required request shape:

- `operation: "git_commit"`;
- non-empty bounded `message`;
- `expectedHead`;
- `expectedIndexTree`;
- non-empty `reason`;
- explicit caller idempotency key through the existing provider boundary;
- optional bounded evidence controls such as `maxStatusBytes` and
  `maxDiffBytes`.

Required resource/event shape:

- Add a `git_commit` resource kind with schema id
  `tron.resource.git_commit.v1`.
- Resource payload should include schema version, state, repository facts,
  branch, parent head, expected head, expected index tree, actual tree, commit
  oid, bounded commit message metadata, reason, authority, before/after
  status/diff evidence, trace refs, replay refs, idempotency, revision, and
  created timestamp.
- Resource lifecycle states should start with `committed` and `archived`.
- Publish a `git.lifecycle` event such as `git.commit_created` pointing to the
  `git_commit` resource and carrying commit oid, parent head, branch, reason,
  authority grant id, and actor id.
- Compensation is manual-only: reset/revert/cherry-pick workflows remain
  future source-control slices.

Likely implementation files/domains to inspect or touch:

- `packages/agent/src/domains/git/{mod.rs,contract.rs,handlers.rs,service.rs,types.rs,tests.rs}`;
- likely new `packages/agent/src/domains/git/commit.rs` or a carefully split
  mutation module if line budgets require it;
- `packages/agent/src/domains/capability/operations/{git.rs,mod.rs}`;
- `packages/agent/src/domains/capability/contract.rs`;
- `packages/agent/src/engine/durability/resources/{types.rs,git_definitions.rs}`;
- `packages/agent/src/domains/model/providers/openai/message_converter/{mod.rs,tests.rs}`;
- static guard inventories and tests under `packages/agent/tests/`, especially
  BPRC, DESI, HRA, PCC, TPC, TMB, SACB, DRC, and IARM as touched;
- README capability and Git/source-control sections plus this scorecard,
  inventory, evidence manifest, and retrospective tracker closeout records.

Deterministic tests required:

- successful commit from staged changes advances the current branch from
  `expectedHead` and records the new commit oid, parent oid, tree oid,
  resource ref, and stream cursor;
- unstaged and untracked worktree changes remain uncommitted and unchanged;
- idempotency replay with the same caller key returns the original commit
  resource/cursor and does not create a second commit;
- stale `expectedHead` rejects before commit;
- stale `expectedIndexTree` rejects before commit;
- empty staged index rejects before commit;
- detached HEAD rejects before commit;
- conflicted/unmerged index rejects before commit;
- non-repo, nested-repo misuse, absolute path/traversal/root escape, missing
  trusted working-directory metadata, empty message, and empty reason reject;
- commit hooks/editor/signing/pager/credential prompts are suppressed or
  fail-closed without running user-controlled hook behavior;
- bounded before/after status and diff evidence reports truncation flags;
- provider schema and instruction tests expose `git_commit` while continuing
  to reject `git_merge`, `git_rebase`, `git_reset`, `git_push`,
  `git_checkout`, and other later source-control operation names;
- resource-definition tests cover `git_commit` schema required fields,
  lifecycle states, link relations, and required capabilities.

Explicit non-goals:

- no auto-staging, unstaging, file edits, conflict resolution, or index repair;
- no branch creation, checkout, deletion, rename, or detached-HEAD commit
  support;
- no merge, rebase, reset, revert, cherry-pick, stash, clean, fetch, pull,
  push, remote configuration, or PR handoff;
- no worktree graph resource acquisition/release or repo import/tree
  visualization;
- no native iOS SourceChanges UI or public `/engine` DTO expansion;
- no production deployment behavior and no `tron deploy`;
- no hidden approval policy changes. Package-wide risky-action approvals wait
  for a later policy decision, though the resource/event evidence should be
  sufficient for future approval checks.

#### Slice 6C Accepted Implementation Note

Implementation branch `codex/phase-2-slice-6c-git-commit-evidence` starts from
`origin/main@bc469ba3458ecce8301eb84abbd82070cfd0362a`. The accepted
implementation adds only `git_commit` through the existing
`capability::execute` and `domains/git` boundaries, with staged-index tree
freshness, resource/stream evidence, hook/editor/pager/signing/prompt
suppression, merge/sequencer rejection, guarded branch compare-and-swap, and
symbolic HEAD lock/recheck protection. It is recorded as an accepted mainline
baseline after the independent review/fix loop.

Review outcome and residual risks:

- First review thread `019ef9e2-1d45-7301-b20e-c7df03274a22` required fixes
  for resolved merge-state rejection and stale mutation-boundary guarding.
- Fix thread `019ef9e7-6156-7bf1-8082-945be924808a` produced
  `f603ea566de9b021ec14cdc123f3cf71b43f1bad`, replacing porcelain commit with
  commit-tree, commit object verification, and guarded branch ref update.
- Re-review thread `019ef9f0-1a49-74c2-982d-b5bd08340256` required a fix for
  symbolic HEAD branch drift between preflight and final ref update.
- Fix thread `019ef9f4-ffa5-7221-b5ac-3af6489bb65c` produced
  `6ec2e03baf03bf260e8e1d3522c93ef8bdeb563f`, adding HEAD lock/recheck
  protection and deterministic synthetic-gitdir branch CAS handling.
- Final review thread `019efa01-45ba-77b2-a2be-b8c0d2ac1d18` returned
  `slice accepted` with no findings after source inspection and focused
  validation.
- Abrupt process termination can still leave a normal Git-style `HEAD.lock`
  until cleanup, matching interrupted Git operation behavior; normal error
  paths remove the lock.

iOS validation: no native SourceChanges UI is part of Slice 6C. Run iOS tests
only if generic runtime/resource rendering changes.

Docs/static updates for implementation: README current operations and
Git/source-control paragraph, Phase 2 scorecard/evidence/inventory, resource
definition docs/tests, provider instruction tests, BPRC current-baseline
wording, retrospective tracker, and any static inventory rows for touched
source files.

Validation commands:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`;
- `cargo check --manifest-path packages/agent/Cargo.toml`;
- `cargo test --manifest-path packages/agent/Cargo.toml git -- --nocapture`;
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`;
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture`;
- targeted static gates for touched inventories: BPRC, DESI, HRA, PCC, TPC,
  TMB, SACB, DRC, and IARM as applicable;
- `scripts/personal-info-guard.sh`;
- `git diff --check`.

iOS validation: no native SourceChanges UI is part of Slice 6C.

Docs/static updates: README capabilities, Phase 2 scorecard/evidence/inventory,
retrospective tracker, provider instruction tests, and static guard inventories.

User decisions: default branch naming, push/PR approval, native source-control
UI scope, and conflict-resolution delegation.

#### Selected Slice 6D Discovery Packet

Exact next slice to implement: **Slice 6D: Git Branch Start Foundation**.

Why this slice is next: accepted Slice 6C can create local commits, but the
agent still cannot move work off the current integration branch before making
or committing changes. A local branch-start operation is the narrowest useful
follow-up because it enables a safe `codex/...` work branch without remote
network behavior, PR handoff, arbitrary checkout, merge/rebase/reset,
conflict-resolution UI, or worktree graph management.

User-facing objective: let the agent create one new local branch at the
currently reviewed HEAD and make it the current branch, preserving the existing
index and worktree content exactly. This supports future local file/stage/commit
work on a named task branch before any push or PR workflow exists.

Core versus modular split:

- Core/harness: reuse the existing `capability::execute` primitive, authority
  grants, idempotency ledger, resource kernel, stream substrate, trace/replay
  refs, and bounded Git command helpers. Add only generic resource definition
  constants/schema wiring needed for a `git_branch_start` evidence resource.
- Modular package: keep behavior in `domains/git`. Add backend branch-start
  service code plus a provider-visible `git_branch_start` operation value
  through `capability::execute`; do not add a second model-facing tool, public
  `/engine` API, native iOS SourceChanges surface, or a broad `worktree` domain.
- Mutation boundary: `git_branch_start` may create exactly one local
  `refs/heads/<branchName>` ref at `expectedHead` and move symbolic `HEAD` to
  that ref after a locked check proves the old symbolic branch and resolved OID
  still match the preflight state. It must not run `git checkout`, write
  worktree files, stage/unstage, commit, delete or rename branches, set
  upstreams, fetch, pull, push, merge, rebase, reset, stash, clean, or create
  PRs.
- Worktree preservation boundary: the operation must prove before/after index
  and worktree evidence is unchanged except for branch identity. Staged,
  unstaged, and untracked files may be preserved only when the target branch is
  created at the current `expectedHead`; conflicted/unmerged index state and
  in-progress merge/rebase/cherry-pick/sequencer state must reject.
- Branch-name boundary: validate the caller-supplied branch name as a local
  branch ref, reject traversal/ref-injection/reserved names and existing local
  branches, and reject branch names that resolve outside `refs/heads/` or imply
  remote/upstream configuration.
- Hook/network boundary: branch start must be non-interactive, must not run
  checkout hooks, editors, pagers, credential prompts, GPG helpers, or network
  commands, and must not modify production deployment state.

Required request shape:

- `operation: "git_branch_start"`;
- `branchName`;
- `expectedHead`;
- non-empty `reason`;
- explicit caller idempotency key through the existing provider boundary;
- optional bounded evidence controls such as `maxStatusBytes` and
  `maxDiffBytes`.

Required resource/event shape:

- Add a `git_branch_start` resource kind with schema id
  `tron.resource.git_branch_start.v1`.
- Resource payload should include schema version, operation
  `branch_start`, state, repository facts, previous branch, new branch name,
  expected head, actual head, reason, authority, before/after bounded
  status/diff evidence,
  trace refs, replay refs, idempotency, revision, and created timestamp.
- Resource lifecycle states should start with `started` and `archived`.
- Publish a `git.lifecycle` event such as `git.branch_started` pointing to the
  resource and carrying branch name, branch ref, previous branch/head,
  expected head, reason, authority grant id, and actor id.
- Compensation after a successful branch start is manual-only; branch
  deletion/rename remains a future source-control slice.

Likely implementation files/domains to inspect or touch:

- `packages/agent/src/domains/git/{mod.rs,contract.rs,handlers.rs,service.rs,types.rs,tests.rs}`;
- new `packages/agent/src/domains/git/branch_start.rs` plus small shared
  helpers if the existing commit HEAD-lock/ref-update code should be reused;
- `packages/agent/src/domains/capability/operations/{git.rs,mod.rs}`;
- `packages/agent/src/domains/capability/contract.rs`;
- `packages/agent/src/engine/durability/resources/{types.rs,git_definitions.rs}`;
- `packages/agent/src/domains/model/providers/openai/message_converter/{mod.rs,tests.rs}`;
- static guard inventories and tests under `packages/agent/tests/`, especially
  BPRC, DESI, HRA, PCC, TPC, TMB, SACB, DRC, and IARM as touched;
- README capability and Git/source-control sections plus this scorecard,
  inventory, evidence manifest, and retrospective tracker closeout records.

Deterministic tests required:

- successful branch start from a named branch creates `refs/heads/<branchName>`
  at `expectedHead`, moves symbolic `HEAD` to that branch, records the resource
  ref and stream cursor, and leaves `rev-parse HEAD` unchanged;
- staged, unstaged, and untracked worktree content is preserved byte-for-byte
  and remains visible in before/after status evidence;
- idempotency replay with the same caller key returns the original branch
  resource/cursor and does not create or switch another branch;
- stale `expectedHead` rejects before creating a branch;
- existing branch name, invalid branch name, remote-like/ref-injection branch
  name, detached HEAD, non-repo, nested-repo misuse, absolute path/traversal/
  root escape, missing idempotency, and missing trusted working-directory
  metadata reject;
- conflicted/unmerged index and in-progress merge/rebase/cherry-pick/sequencer
  state reject;
- checkout hooks, editors, pagers, credential prompts, GPG helpers, and network
  commands are not invoked;
- bounded before/after status and diff evidence reports truncation flags;
- provider schema and instruction tests expose `git_branch_start` while
  continuing to reject `git_checkout`, `git_branch_delete`,
  `git_branch_rename`, `git_merge`, `git_rebase`, `git_reset`, `git_push`,
  and other later source-control operation names;
- resource-definition tests cover `git_branch_start` schema required fields,
  lifecycle states, link relations, and required capabilities.

Explicit non-goals:

- no arbitrary branch checkout or switching to an existing branch;
- no branch deletion, rename, upstream/tracking setup, default branch
  auto-detection policy, or detached-HEAD commit support;
- no file edits, staging/unstaging, commit creation, conflict resolution, or
  index repair;
- no merge, rebase, reset, revert, cherry-pick, stash, clean, fetch, pull,
  push, remote configuration, or PR handoff;
- no worktree graph resource acquisition/release or repo import/tree
  visualization;
- no native iOS SourceChanges UI or public `/engine` DTO expansion;
- no production deployment behavior and no `tron deploy`;
- no hidden approval policy changes. Push/PR approval and branch deletion
  approval wait for later policy slices.

Docs/static updates for implementation: README current operations and
Git/source-control paragraph, Phase 2 scorecard/evidence/inventory,
retrospective tracker, provider instruction tests, resource definition
docs/tests, BPRC current-baseline wording, and static guard inventories.

Validation commands:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`;
- `cargo check --manifest-path packages/agent/Cargo.toml`;
- `cargo test --manifest-path packages/agent/Cargo.toml git -- --nocapture`;
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`;
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::model::providers::openai::message_converter -- --nocapture`;
- targeted static gates for touched inventories: BPRC, DESI, HRA, PCC, TPC,
  TMB, SACB, DRC, and IARM as applicable;
- `scripts/personal-info-guard.sh`;
- `git diff --check`.

iOS validation: no native SourceChanges UI is part of Slice 6D. Run iOS tests
only if generic runtime/resource rendering changes.

User decisions still deferred after Slice 6D: push/PR approval, arbitrary
checkout policy, branch deletion/rename policy, native source-control UI scope,
and conflict-resolution delegation.

### Slice 7: Goals, Queues, Questions, And Planning

Objective: restore durable autonomous work objects and user-question flows.

User-facing outcome: users can create/inspect/cancel goals, answer questions,
see queue state, and review plans backed by real events.

True primitives: engine queues, resources, streams, approvals, memory traces,
and replay.

Modular boundaries: goal/question package owns objective records, queue items,
plan resources, user question resources, answers, and inbox events.

Likely files/areas: `domains/agent/loop`, `engine/durability/queue`,
resources/events, iOS `Interaction` protocol and future Work surface.

Old evidence paths: `BPRC-FEATURE-08`, `IARM-SURFACE-027`,
`IARM-SURFACE-028`, feature index section 8.

Acceptance criteria: interruptible goals, explicit ownership, question expiry,
answer provenance, queue backpressure, cancellation, replay, and no fake local
question sheets.

Focused tests: goal lifecycle, queue ordering, question/answer idempotency,
cancellation, plan versioning, iOS answer flow, CSD queue rows.

iOS validation: simulator/Computer Use for question and goal UI if native.

Docs/static updates: README event/capability sections, iOS architecture,
queue/resource inventories.

User decisions: default goal autonomy, when questions interrupt, and whether a
Work dashboard is native or generated first.

### Slice 8: Web, Research, Browser, And Fetch

Objective: restore network research with provenance and explicit authority.

User-facing outcome: the agent can search/fetch/browse sources, cite evidence,
cache fetches, and show source records.

True primitives: network authority scope, resource records, trace, replay, and
redaction.

Modular boundaries: web/research package owns search providers, fetch cache,
HTML/text extraction, browser status if added, and source provenance.

Likely files/areas: future `domains/web`, future external browser/research
workers, resource store, model context assembly, iOS generic source rendering.

Old evidence paths: `BPRC-FEATURE-04`, `IARM-SURFACE-030`, feature index
section 4.

Acceptance criteria: network access is never smuggled through process
execution, source records carry URL/time/hash/provider, sensitive data is
redacted, cache policy is explicit, and citations are replayable.

Focused tests: authority denial, fetch bounds, cache hashing, redaction,
robots/provider policy if adopted, source rendering, dependency review for
HTML parsing.

iOS validation: generic source/result rendering screenshots if UI changes.

Docs/static updates: README capabilities/dependencies, SACB inventory,
dependency inventory.

User decisions: allowed search/fetch providers, default network mode,
retention, and browser automation scope.

### Slice 9: Worker Self-Extension, MCP, Plugins, And Tool Sources

Objective: let Tron install and run external capability packages safely.

User-facing outcome: users can inspect proposed packages, source identity,
permissions, conformance, runtime status, and disable/retire packages.

True primitives: existing `worker_lifecycle`, `/engine/workers`, catalog,
grants, resource leases, package resources, and conformance reports.

Modular boundaries: source/package manager owns MCP servers, plugin sources,
package provenance, sandbox policy, install/update/uninstall, and conformance.
Runtime workers connect through the existing external-worker protocol.

Likely files/areas: `domains/worker_lifecycle`, `engine/runtime`,
`engine/catalog`, `engine/authority`, future MCP/source modules, iOS Agent
Cockpit.

Old evidence paths: `BPRC-FEATURE-06`, `BPRC-FEATURE-14`,
`IARM-SURFACE-032`, feature index sections 6 and 14.

Acceptance criteria: package proposal is inert until approved; install is
auditable; scoped tokens bind subject/session/workspace; conformance must pass;
disable/retire is reversible; source identity and sandbox policy are visible.

Focused tests: manifest validation, token hash, scoped stream/function
registration, conformance mismatch, install rollback, MCP schema provenance,
SACB external-worker guards.

iOS validation: Agent Cockpit package/source UI screenshots if changed.

Docs/static updates: README worker lifecycle/MCP/dependency sections, SUWRF
inventory, SACB/CSD/PERF rows.

User decisions: approved source roots, MCP trust policy, package signing, and
whether agent-authored packages can self-propose.

### Slice 10: Subagents And Delegation

Objective: restore parallel agent work as durable jobs/workers with causality.

User-facing outcome: users can see child tasks, status, logs, cancellation,
results, and parent integration decisions.

True primitives: jobs, worker lifecycle, queues, resources, approvals, memory,
and replay.

Modular boundaries: subagent package owns parent-child task records, model
profile selection, result resources, delegation authority, and merge decisions.

Likely files/areas: `domains/agent/loop`, future `domains/subagents`, jobs,
worker packages, iOS capability evidence and generated surfaces.

Old evidence paths: `BPRC-FEATURE-07`, `IARM-SURFACE-026`, feature index
section 7.

Acceptance criteria: every subagent has parent trace, authority, workspace,
model profile, cancellation path, result resource, and replay evidence.

Focused tests: spawn/status/result/cancel lifecycle, parent budget, result
merge, failure semantics, iOS projection, CSD task ownership.

iOS validation: simulator/Computer Use if native subagent chips/sheets return.

Docs/static updates: README capabilities/events, iOS architecture, queue/job
inventories.

User decisions: maximum concurrency, model presets, when delegation requires
approval, and default UI placement.

### Slice 11: Skills, Rules, Hooks, And Procedural Memory

Objective: restore adaptive behavior as resource-backed, evaluated, and
auditable procedural state.

User-facing outcome: users can inspect active procedures, rules, hooks, skills,
eval status, provenance, and disable/edit/delete them.

True primitives: memory contract, resource kernel, eval resources, trigger
substrate, approvals, and context inclusion trace.

Modular boundaries: procedural package owns skill/rule/hook records and
activation policy. It does not recreate `packages/agent/skills/` or bootstrap
prompt injection.

Likely files/areas: memory resources, trigger runtime, future
`domains/procedural`, context assembly, iOS memory/procedure audit.

Old evidence paths: `BPRC-FEATURE-10`, `IARM-SURFACE-021`,
`IARM-SURFACE-034`, feature index section 10.

Acceptance criteria: every active procedure has provenance, lineage, evals,
scope, trigger, prompt-inclusion reason, rollback, and disable behavior.

Focused tests: activation/deactivation, trigger policy, eval pass/fail,
context inclusion, deletion, SSARR no repo-managed skills guard.

iOS validation: memory/procedure audit screenshots if native surfaces return.

Docs/static updates: README context, memory docs, SSARR/TPC guards.

User decisions: whether agent-authored rules are allowed, required eval
thresholds, and trigger categories.

### Slice 12: Scheduling, Reminders, Automations, And Background Work

Objective: restore durable scheduled work through explicit triggers and run
records.

User-facing outcome: users can create/cancel/inspect reminders, monitors,
recurring automations, missed runs, and background results.

True primitives: trigger runtime, queues, resources, grants, leases, run
records, and notifications.

Modular boundaries: scheduler package owns schedules, timezone policy, missed
runs, run records, and cancellation. Feature packages own what scheduled work
does.

Likely files/areas: engine trigger runtime, queue, resources, future
`domains/scheduler`, iOS schedule surfaces after contract.

Old evidence paths: `BPRC-FEATURE-17`, feature index section 17.

Acceptance criteria: durable schedule schema, timezone/missed-run policy,
authority on each run, cancellation, replay, retention, and no hidden cron
tables outside the module.

Focused tests: trigger firing, missed-run behavior, cancellation, schedule
edits, clock injection, CSD timer fairness, APNs handoff if notification is
used.

iOS validation: simulator screenshots if schedule UI changes.

Docs/static updates: README event/database/settings, CSD inventory.

User decisions: supported schedule grammar, timezone behavior, missed-run
policy, and default notification path.

### Slice 13: Notifications, APNs, Device Broker, And Inbox

Objective: restore notification delivery only after server-owned device and
notification resources exist.

User-facing outcome: users can register devices, receive push notifications,
open an inbox, mark read, inspect delivery evidence, and control badges.

True primitives: device resource, notification resource, delivery event,
per-device token custody, approval/user-attention policy, and APNs transport
boundary.

Modular boundaries: notification/device package owns APNs registration,
delivery, read state, token invalidation, retention, and privacy. iOS owns
permission prompts and local presentation only.

Likely files/areas: future `domains/device`, future `domains/notifications`,
platform APNs, iOS app delegate/entitlements/inbox after backend proof.

Old evidence paths: `BPRC-FEATURE-12`, `IARM-SURFACE-019`,
`IARM-SURFACE-033`, Phase 1 Slice 6 progress ledger.

Acceptance criteria: no fake local inbox; device tokens are secret; APNs
environment is explicit; delivery/read state is durable; badge semantics are
defined; source-control/process/job/subagent/approval/web/research/skills/rules
memory notification families map to real events.

Focused tests: device register/unregister, token redaction, delivery success
and failure, read state, APNs environment, iOS permission/deep-link handling,
physical-device validation for push.

iOS validation: simulator for inbox UI plus physical device for APNs.

Docs/static updates: README capabilities/settings/database, iOS architecture,
privacy, entitlements, SACB inventory.

User decisions: which events notify by default, badge policy, privacy/retention,
and whether push is opt-in.

### Slice 14: Media, Voice Notes, Imports, Repository Trees, And System Updates

Objective: restore lower-priority product surfaces only after the core
agent-execution patterns are proven.

User-facing outcome: persistent voice/media artifacts, import previews, session
tree/history views, repository divergence, and update diagnostics are available
where they have stable owners.

True primitives: artifact resources, storage refs, replay, settings parity,
approval, and package-specific events.

Modular boundaries: media package owns upload/storage/transcription resources;
import/history package owns graph operations; update package owns signed update
checks and never production deployment.

Likely files/areas: future media/import/update domains, storage resources,
iOS native surfaces only where generic UI is insufficient.

Old evidence paths: `BPRC-FEATURE-13`, `BPRC-FEATURE-16`,
`BPRC-FEATURE-18`, `BPRC-FEATURE-19`, `BPRC-FEATURE-20`,
`BPRC-FEATURE-21`, `BPRC-FEATURE-22`, `BPRC-FEATURE-23`,
`BPRC-FEATURE-24`, IARM media/session/system rows.

Acceptance criteria: storage/migration/retention policy, settings parity,
event schemas, dependency review, iOS parity decision, and no deploy automation.

Focused tests: media bounds/redaction, import preview/execute, tree lineage,
update signature/provenance, settings parity, migration rollback, iOS decoder
tests.

iOS validation: simulator/Computer Use for native surfaces; physical device if
media capture or permissions change.

Docs/static updates: README database/settings/dependencies, iOS docs,
release/manual-deploy boundary.

User decisions: which low-priority panels are worth native UI, media retention,
and update-check policy.

## Handoff Packet Required Before Each Slice

Every future implementation thread must present this packet before coding:

1. First-principles UX review: user value, minimal shape, what is useful for a
   self-adapting agent, what old behavior is evidence only, and what stays
   absent.
2. Architecture review: true primitives touched, package/module owner,
   functions/triggers, resources/events, authority, scheduling, replay,
   storage, settings, dependency, iOS parity, rollback, and static gates.
3. Source evidence: BPRC feature ids, IARM rows, old paths/contracts, current
   replacement/gap, and relevant hardening artifacts.
4. User decisions: explicit questions with recommended defaults and risk
   tradeoffs.
5. Acceptance and validation plan: focused Rust tests, invariant tests,
   migration tests, iOS simulator/Computer Use/physical-device validation as
   applicable, docs/README/progressive disclosure, and inventory updates.

No implementation thread should start by copying old code. It should start by
answering this packet and getting user approval for the slice shape.

## Validation Protocol

Planning/docs minimum:

- `scripts/personal-info-guard.sh`
- `git diff --check`
- `git ls-files -ci --exclude-standard`
- relevant existing invariant tests for touched docs/inventories

Implementation slices add:

- focused Rust `cargo fmt --all -- --check`, `cargo check`, and targeted tests;
- migration/replay/resource/event tests for storage changes;
- SACB/CSD/PERF/ODA/static inventory checks for authority, scheduling,
  resources, and diagnostics changes;
- iOS `xcodegen generate`, focused Swift tests, simulator screenshots, and
  Computer Use validation when Swift UI changes;
- physical-device validation for APNs, microphone/camera, background
  notification, or device-token flows;
- README, domain `mod.rs`, iOS docs, and machine-readable inventory updates.

## Scorecard

| Row | Name | Points | Status | Closure |
| --- | --- | ---: | --- | --- |
| P2AER-0 | Baseline, branch, and planning-only scope | 8 | passed | Current branch and baseline HEAD are recorded; inspected artifacts are listed; no feature implementation scope is explicit. |
| P2AER-1 | Phase 1 deferral carry-forward | 10 | passed | Every Phase 1 reminder and Slice 6 notification/APNs deferral is carried into the inventory and roadmap. |
| P2AER-2 | BPRC feature coverage | 12 | passed | All 24 BPRC backlog buckets are represented in the roadmap and machine-readable TSV. |
| P2AER-3 | Primitive-vs-capability classification | 10 | passed | Each family is classified as true primitive, modular capability/package, iOS surface only, server-fact rendering only, deferred, or reject candidate. |
| P2AER-4 | Deep hot-swappable memory design | 14 | passed | Memory primitives, engine contract, store families, privacy, migration, eval, swapping, iOS audit, and hidden-memory guards are specified. |
| P2AER-5 | Ordered slice roadmap | 16 | passed | Each slice records objective, user outcome, primitives, modular boundaries, likely files, evidence paths, acceptance criteria, tests, iOS validation, docs/static updates, and user decisions. |
| P2AER-6 | Safety, authority, scheduling, and validation gates | 10 | passed | SACB/CSD/TPC/HRA constraints are folded into every risky feature family and validation protocol. |
| P2AER-7 | iOS parity and native-surface discipline | 8 | passed | Generic runtime rendering is the default; native iOS surfaces require stable backend contracts and simulator or device validation. |
| P2AER-8 | Machine-readable inventory and evidence manifest | 7 | passed | The TSV has a stable schema, old evidence paths, status, owners, backend dependency, memory involvement, and validation requirements. |
| P2AER-9 | Handoff readiness | 5 | passed | Future implementation threads have a required pre-slice handoff packet and explicit user-question format. |

## Closure Verdict

Phase 2 remains source-backed and proceeds one slice at a time. As of
`main@6ec2e03baf03bf260e8e1d3522c93ef8bdeb563f`, Slices 1 through 4,
Slice 5A, Slice 6A, Slice 6B, and Slice 6C are represented on the consolidated
mainline after independent acceptance. The next Phase 2 action is a discovery
thread for the next narrow Slice 6 source-control boundary from fresh
`origin/main`, preserving branch/worktree graph, merge/rebase/reset, remote,
PR handoff, conflict workflow, production deploy, and native SourceChanges
deferred scope until explicitly shaped.

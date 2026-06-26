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

Discovery update: 2026-06-25.

Canonical plan file: this scorecard. The README names this file as the durable
Phase 2 plan, while the inventory and evidence manifest are companion
machine-readable and validation artifacts.

Current implementation baseline verified for Slice 9B closeout:
`main@cd97c2f87afa3e961258eedf37a227926e496720`
(`fix: redact worker lifecycle grant metadata`) plus this Slice 9B closeout
documentation commit. That line includes accepted Slice 6A
read-only Git/worktree status and diff evidence, accepted Slice 6B index-only
stage/unstage, accepted Slice 6C staged-index commit evidence, accepted Slice
6D local branch-start evidence, accepted Slice 6E read-only branch inventory
evidence, accepted Slice 7A goal/question lifecycle evidence, accepted Slice 8A
web fetch/source provenance evidence, and accepted Slice 8B web source
citation/inspection evidence, accepted Slice 8C HTML/XHTML readable-text
extraction evidence, and accepted Slice 8D web source archive lifecycle
evidence, accepted Slice 8E web robots policy evidence, accepted Slice 8F web
fetch robots evidence linkage, accepted Slice 9A tool-source proposal
provenance evidence, accepted Slice 9B worker-package lifecycle inspection
evidence, accepted Slice 10B subagent worker launch foundation evidence,
accepted Slice 11A procedural state provenance and inspection evidence, and
accepted Slice 12 scheduler foundation evidence.

Closeout note: Slice 8C is accepted after implementation thread
`019efb88-d1f1-7ef2-b90d-96254eb51679`, review thread
`019efb99-ee44-7901-b70a-56ea4643f302`, focused fix thread
`019efb9e-766b-7273-862b-5e739ac73c01`, and re-review thread
`019efbac-4560-7382-a034-4ef36854367f`. The initial review required safe title
redaction/bounds and HRA ownership-map coverage; fix commit
`5e881e8681229545fe8260a1dc2be8f47cd07a3a` addressed both, and re-review
returned `slice accepted` with no findings. Direct URL fetch provenance,
read-only source inspection, and deterministic HTML/XHTML readable-text
extraction are accepted; later search providers, browser automation, crawling,
robots policy, login/cookies/session reuse, native source UI, public `/engine`
web APIs, and network-enabled jobs remain deferred.

Closeout note: Slice 8D is accepted after implementation thread
`019efbbd-f745-7752-8cd8-fdd86194d138` and independent review thread
`019efbd4-b199-71c2-b56d-4d8c7aa02976`. Implementation commit
`3a9d4f35674b166528d7e15aea0e17802d634cea` adds execute-only
`web_source_archive`, append-only source archive lifecycle metadata, default
active source listing, explicit archived inclusion, exact archived inspection,
and no-network archive/list/inspect behavior. Review returned `slice accepted`
with no findings. Search providers, browser automation, crawling, robots
policy, login/cookies/session reuse, native source UI, public `/engine` web
APIs, deletion/pruning/automatic TTL cleanup, and network-enabled jobs remain
deferred.

Closeout note: Slice 8E is accepted after implementation thread
`019efbe9-ea1a-7e73-93a9-5c2ddcf67e76`, review thread
`019efc06-2c7d-76b2-a773-8cbcf0a2ca8a`, first focused fix thread
`019efc0a-d75e-7032-810f-f81f0f5ed15b`, first re-review thread
`019efc18-7248-7ad3-9f38-647283af6f0f`, second focused fix thread
`019efc1e-0ce8-79a1-a89a-d028333b7e9a`, and accepting re-review thread
`019efc26-2fca-7dc3-abf2-c8d1dbab81b5`. Implementation commit
`ca336f6aed4f9582bd4e7d6738ebc2410728f80f` added execute-only
`web_robots_check`; fix commits `b0352fbb79f30b267d8725deaf3fc2e234ec5998`
and `21d3d24a7f757b43d3f51599fe35a14e7f0f3633` addressed production HTTP
loopback rejection, robots module hard-budget split, and `resource.read`
authority enforcement for `web_robots_policy` cache/evidence reads. Final
re-review returned `slice accepted` with no findings.

Closeout note: Slice 8F is accepted after discovery thread
`019efc32-30b1-7811-9959-7e539ba8062f`, implementation thread
`019efc38-4532-7d02-97d2-67149b834f76`, first review thread
`019efc5c-dead-76c0-8cb3-496dba956a06`, focused fix thread
`019efc66-358e-7571-8508-6e691c663e49`, and accepting re-review thread
`019efc78-a769-76a0-97fe-e75601b0955a`. Implementation commit
`c01924ba634b64ec0bdb6033bd53dc304b5a94fc` connected optional current-session
allow `web_robots_policy` evidence to `web_fetch` source provenance; fix commit
`cb30347b29d7e11d8e0e4210068ee67e6cabd9f0` added exact target fingerprint
validation for sanitized sensitive URLs and aligned explicit-null robots fields
with ordinary fetch grant semantics. Final re-review returned `slice accepted`
with no findings.

Closeout note: Slice 9A is accepted after discovery thread
`019efc87-5b5f-7cd0-82c8-9491b6266377`, implementation thread
`019efc8e-09dc-7b61-9b63-1a7df6fbe99a`, initial review thread
`019efca9-05e9-7b43-8c88-3396f57dd791`, replacement focused fix thread
`019efcb6-9530-7dc1-b515-789ab8e656a1`, re-review thread
`019efcc2-007f-79c1-87f8-a9200369f79f`, focused fix thread
`019efcca-8dcc-70c1-b401-4af360bbab38`, re-review thread
`019efce1-b995-70e1-95a2-2de9644d7e2e`, final focused fix thread
`019efcea-c8e6-7a70-ae89-d96942d4aaa0`, and accepting re-review thread
`019efcf5-050b-7320-b9ce-d4b248f4c61d`. Implementation commit
`2bd51fcf38d68720ee4ed25937b393b8450ecbe0` added the inert
`tool_sources` domain, trusted internal proposal/report resources, and
read-only `tool_source_list`/`tool_source_inspect` execute operations. Fix
commits `788b105980b59d73b5e0c05eb682c81b669827ad`,
`8fcb3051dc0359e558ffac9dfe77f525709f1c92`, and
`2c472ed7ded121e1e2210156d89526b70e28ad65` addressed conformance-report
resource-kind authority, string-valued activation/registration intent,
stored-kind/schema revalidation during inspect, passive/noun activation intent,
stale evidence wording, split test-file static inventory coverage, and
premature README accepted-baseline wording. Final re-review returned
`slice accepted` with no findings.

Closeout note: Slice 9B is accepted after discovery thread
`019efd04-598f-7232-a24e-5ba85f0d4d56`, implementation thread
`019efd0b-3461-79c0-8d28-7a11fdcb9703`, initial review thread
`019efd21-89f2-7951-9efe-242402f9604d`, focused fix thread
`019efd2a-de81-7b02-9605-32d93153b9a9`, re-review thread
`019efd3e-7bac-7ec1-b67e-2c22d60f2886`, second focused fix thread
`019efd4b-0240-7a41-a401-701346bee279`, and accepting re-review thread
`019efd54-5da3-7842-bf6e-6e66a1d83472`. Implementation commit
`ce56ff609948d0d31dbd76e74a30a87a027738d3` added read-only
`worker_package_list` and `worker_package_inspect` execute operations for
existing worker lifecycle resources. Fix commits
`7c794417c1b5b6490324fa6e1062580b73f339a8` and
`cd97c2f87afa3e961258eedf37a227926e496720` addressed provider runtime grant
derivation, wildcard selector denial, archived proposal/conformance exclusion,
inspection file-budget splitting, direct installation authority-grant redaction,
and nested grant-id metadata redaction. Final re-review returned
`slice accepted` with no findings.

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
  lifecycle evidence;
- Slice 6D: local branch-start with guarded symbolic `HEAD` movement, resource
  evidence, lifecycle evidence, and no checkout;
- Slice 6E: read-only local branch inventory evidence through
  `git_branch_inventory`, including bounded truncated metadata handling;
- Slice 7A: durable goal/question lifecycle records, bounded backend evidence,
  and explicit execute authority/resource checks without autonomous execution;
- Slice 8A: direct `web_fetch` source provenance with declared-network
  authority, bounded evidence, `web_source` resources, and no search/browser
  scope;
- Slice 8B: read-only current-session `web_source` list/inspect
  citation fields through `capability::execute`, with no new network breadth.
- Slice 8C: deterministic HTML/XHTML readable-text extraction under existing
  `web_fetch`/`web_source_*` operations, preserving raw-byte source hashes and
  adding safe extraction metadata without search/browser breadth.
- Slice 8D: current-session `web_source_archive` lifecycle updates,
  default active-source listing, explicit archived-source inclusion, and exact
  archived inspection for replay/citation audit.
- Slice 8E: declared-network `web_robots_check` for one origin `robots.txt`,
  bounded `web_robots_policy` evidence, sitemap refs as metadata only, and
  fail-closed authority/URL/redirect/DNS checks before target network I/O.
- Slice 8F: optional `web_fetch` robots evidence linkage, exact current-session
  allow policy validation before target network I/O, bounded
  `robotsPolicyRefs` on source list/inspect, and ordinary fetch compatibility
  without global robots requirements.
- Slice 9A: inert external tool-source proposal/provenance records and
  read-only source inspection through `capability::execute`, with trusted
  internal-only writes, bounded/redacted evidence, explicit resource-kind
  authority, and no install/launch/registration/execution behavior.
- Slice 9B: read-only worker-package lifecycle list/inspect evidence through
  `capability::execute`, with trusted current-session context, explicit
  `worker.lifecycle.read`/`resource.read` authority, non-wildcard worker
  selectors, stored kind/schema revalidation, bounded/redacted lifecycle
  evidence, and no package mutation or execution behavior.
- Slice 10A accepted: inert `subagent_task` lifecycle/provenance records and
  read-only `subagent_task_list`/`subagent_task_inspect` evidence through
  `capability::execute`, with explicit `subagents.read`/`resource.read`
  authority, `kind:subagent_task` selectors, stored kind/schema revalidation,
  scope isolation, allowlisted bounded/redacted read projections, and no
  child-agent, worker, job, process, network, scheduling, or result-merge
  behavior.
- Slice 10B accepted: controlled `subagent_launch`,
  `subagent_status`, `subagent_result`, and `subagent_cancel` lifecycle
  operations through `capability::execute`, preserving `subagent_task` as the
  parent causality anchor with explicit bounded placeholder model policy,
  one-running-task-per-scope concurrency, idempotency/freshness, bounded
  evidence, trace/replay refs, and no worker/job/process/tool/network/package
  launch or result merge.
- Accepted Slice 11A: inert `procedural_record`
  skill/rule/hook/procedure resource contracts plus read-only
  `procedural_state_list` and `procedural_state_inspect` evidence through
  `capability::execute`, with explicit `procedural.read`/`resource.read`
  authority, `kind:procedural_record` and `proceduralKind:*` selectors, stored
  kind/schema/version/status revalidation, bounded/redacted projections, and no
  activation, trigger firing, prompt injection, learned behavior, autonomous
  execution, scheduler work, tool execution, worker/package/job/process/network
  launch, result merge, repo-managed skills, or bootstrap skill-copy wiring.
- Accepted Slice 12: durable `schedule` and `schedule_run` resource contracts,
  `domains/scheduler`, and execute-only `schedule_create`, `schedule_list`,
  `schedule_inspect`, `schedule_cancel`, and `schedule_fire_due` operations
  through `capability::execute`, with explicit `scheduler.read`,
  `scheduler.write`, `scheduler.fire`, and resource authority, non-wildcard
  target selectors, deterministic clock injection, bounded/redacted
  projections, cancellation terminality, bounded fire/inspect scans, and no
  hidden cron loop, direct feature execution, native fixed schedule UI, APNs
  delivery, public scheduler API, autonomous planning, or result merge.

Current next action:
Slice 8A direct fetch source provenance, Slice 8B read-only source inspection,
Slice 8C HTML/text extraction, Slice 8D source archive lifecycle, and Slice 8E
robots policy evidence, Slice 8F robots evidence linkage, and Slice 9A
tool-source proposal provenance, and Slice 9B worker-package lifecycle
inspection, Slice 10A subagent task lifecycle, Slice 10B subagent worker launch
foundation, Slice 11A procedural state provenance inspection, and Slice 12
scheduler foundation are accepted current baseline after independent
review/fix/re-review loops.
Search providers, browser
automation, crawling beyond the narrow robots check, sitemap traversal,
login/cookies/session reuse, native source UI, public `/engine` web APIs,
network-enabled jobs, autonomous goal execution, tool-source or worker-package
install/launch/registration/execution, real subagent worker/process execution,
subagent result merge, procedural activation/triggers/prompt injection/learned
behavior, richer schedule grammar/timezone conversion, real feature-domain
scheduled execution, APNs notification delivery, fetch/pull/push, PR handoff,
production deployment behavior, and native SourceChanges UI remain deferred
until separately scoped and reviewed.

## Scope

This is a planning, handoff, and implementation-evidence artifact. It records
candidate and accepted branch work without making acceptance claims before the
recorded review/fix loop. It does not by itself restore agent-execution
features, add public `/engine` methods, add database migrations, add iOS
product panels, add worker packages, or reintroduce repo-managed first-party
skills.

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
Slice 15A is an implementation candidate for the metadata-only half of this
row: it adds `domains/program_execution`, durable `program_execution_record`
resources, execute-only record/list/inspect operations, exact resource
authority/selectors, bounded/redacted projections, deterministic injected
timestamps, and validation that rejects raw code, raw stdin/stdout/stderr,
command strings, shell snippets, package-manager directives, unsafe paths, and
provider-visible raw payloads. Runtime execution, subprocess/job launch,
interpreter isolation, package installation, file writes, live network behavior,
notebook/PTY UX, and result merge remain future decisions.

Slice 16A is the accepted backend-only prompt
artifact resource foundation under `P2AER-INV-018` / `BPRC-FEATURE-11`: it
adds `domains/prompt_artifacts`, durable `prompt_artifact` resources,
execute-only record/list/inspect operations, exact resource authority/selectors
including `promptArtifactResourceId`, bounded/redacted projections,
deterministic injected timestamps, and validation that rejects raw prompt
bodies, provider-visible raw prompt payloads, raw idempotency keys, unsafe
paths, secrets, token-like material, automatic prompt-history capture, prompt
injection/context inclusion, and learned behavior. Native snippet/template UI,
automatic capture policy, prompt inclusion semantics, settings/profile
migration, and public prompt APIs remain future decisions.

Slice 17A is the accepted backend-only model provider reasoning/status evidence
foundation under `P2AER-INV-024` / `BPRC-FEATURE-20` / `BPRC-FEATURE-21`: it
adds metadata-only reasoning/status evidence at the existing model/responder
audit and turn-persistence boundaries, typed assistant and stream payload
compatibility, bounded provider/model/status/token facts, provider-audit and
trace/replay refs, and redaction policy evidence. Hidden chain-of-thought
exposure, invented reasoning summaries, raw provider reasoning payload
persistence, provider-visible raw reasoning payloads, native reasoning UI,
settings/profile migration, public reasoning APIs, and unrelated DRC cleanup
remain future decisions.

Slice 18A is the accepted backend-only memory query/decision evidence
foundation under `P2AER-INV-015` / `P2AER-INV-016` / `BPRC-FEATURE-10`: it
adds inert `memory_query` and `memory_decision` resources, backend domain
record/list/inspect functions, read-only provider-safe inspection operations,
bounded refs/reason codes/redaction proof/trace and replay refs, deterministic
injected timestamps, fingerprinted idempotency evidence, and explicit
`memory.read`/`resource.read` plus resource-kind/selector enforcement for the
provider-visible execute reads. Semantic/vector retrieval, embeddings, ranking,
summarization, episodic event retrieval, prompt inclusion, automatic retention,
native memory UI, public `/engine` expansion, settings/profile migration, and
unrelated DRC cleanup remain future decisions.

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

#### Slice 6D Accepted Implementation Note

Implementation branch `codex/phase-2-slice-6d-branch-start` starts from
`origin/main@4d7221bf436acce3406d50ab0b1f2a06415616be`. The accepted
implementation adds only `git_branch_start` through the existing
`capability::execute` and `domains/git` boundaries, with safe branch-name
validation, expected-HEAD freshness, conflict/sequencer rejection, idempotency,
resource/stream evidence, dirty-state preservation, checkout/hook suppression,
and locked symbolic-HEAD old-ref/OID recheck protection. It is recorded as an
accepted mainline baseline after the independent review/fix loop.

Review outcome and residual risks:

- First review thread `019efa28-ffe5-7291-b7de-00ab4c700557` required rollback
  hardening for symbolic `HEAD` movement failures after branch creation.
- Fix thread `019efa32-013b-70d1-9fe7-2824c84eda5c` produced
  `2d8d804ce00358800746d46788e03ab584cc12ec`, adding branch-ref rollback
  hardening and deterministic regression coverage.
- Re-review thread `019efa3c-8a0c-7863-9ea7-3d337fa8a7ec` required a guard for
  stale symbolic-HEAD movement if current branch identity or OID drifted before
  the branch switch.
- Focused fix commit `cfff8bc5f732243724dc97c964a613070ef9736c` added locked
  symbolic-HEAD old-ref/OID rechecks and deterministic OID-drift coverage.
- Final review thread `019efa4a-ffdd-7e32-b08e-f175e2a44f1a` returned
  `slice accepted` with no findings after source inspection and focused
  validation.
- Abrupt process termination can still leave a normal Git-style `HEAD.lock`
  until cleanup, matching interrupted Git operation behavior; normal error
  paths remove the lock or use all-or-nothing branch-ref rollback.

#### Selected Slice 6E Discovery Packet

Exact next slice to implement: **Slice 6E: Git Branch Inventory Foundation**.

Why this slice is next: accepted Slice 6D can create and enter a new local
branch without checkout, but the agent still lacks bounded evidence for the
local branch set before any later branch mutation, push/PR handoff, cleanup,
or checkout decision. The current canonical plan still defers arbitrary
checkout, branch deletion/rename, remotes, worktree graph resources, conflict
workflows, and native SourceChanges UI. A read-only branch inventory is the
narrowest useful source-control boundary because it supplies decision evidence
without taking on those deferred mutation policies.

User-facing objective: let the agent inspect local branch state for the trusted
repository root, including the current branch, local branch names/refs, head
oids, upstream names when present, ahead/behind counts when cheaply available,
last-commit summary metadata, and bounded evidence. This helps users and later
slices decide what branch exists, where work lives, and whether a future branch
switch/delete/push/PR operation is even meaningful.

Scope and boundaries:

- True primitive: none beyond the existing `capability::execute`, Git domain,
  trusted working-directory metadata, bounded evidence, and resource/event
  substrate already used by Slices 6A-6D.
- Modular package: keep behavior in `domains/git`. Add a provider-visible
  `git_branch_list` or `git_branch_inventory` operation value through
  `capability::execute`; add a backend read contract only if it fits the
  existing `git::status`/`git::diff` catalog pattern.
- Read-only boundary: this slice must not create, delete, rename, switch, reset,
  merge, rebase, revert, cherry-pick, stash, clean, fetch, pull, push, set
  upstreams, create worktrees, resolve conflicts, mutate the index, or edit
  worktree files.
- Evidence boundary: output must be bounded and deterministic enough for tests;
  caller-controlled byte/count limits affect returned evidence only, never
  whether repository state is read.
- Authority boundary: only trusted working-directory repository metadata is
  accepted. No arbitrary filesystem scan, remote network access, public
  `/engine` DTO expansion, hidden approval policy, or iOS native SourceChanges
  surface is included.

Request/output shape:

- Request fields should include `operation`, optional trusted-root `path`, and
  optional evidence bounds such as `maxBranches` and `maxBranchBytes`.
- Response should include `schemaVersion`, `status`, `operation`,
  `repository`, `currentBranch` or detached-HEAD evidence, `branches`, and
  `evidence`/truncation metadata.
- Each branch row should include local branch name, full ref, oid, current
  marker, optional upstream, optional ahead/behind, and bounded last-commit
  subject/time/author metadata if already available without invoking editors,
  hooks, pagers, credentials, or network.
- No durable resource kind is required unless the implementation needs replay
  custody beyond the normal invocation/result trace; branch inventory is a
  read-only observation, not a source-control effect.

Likely files/areas:

- `packages/agent/src/domains/git/service.rs`;
- `packages/agent/src/domains/git/contract.rs`;
- `packages/agent/src/domains/git/handlers.rs`;
- `packages/agent/src/domains/capability/operations/git.rs`;
- provider operation/schema instruction tests;
- `packages/agent/src/domains/git/mod.rs` docs;
- README capability and Git/source-control sections plus this scorecard,
  evidence manifest, inventory, and TSV.

Deterministic tests:

- clean repository with several local branches returns sorted or otherwise
  documented deterministic branch rows and marks the current branch;
- detached HEAD reports detached evidence without pretending a branch is
  current;
- upstream/ahead-behind evidence is reported for a local fixture with a local
  remote ref and omitted or marked unavailable when no upstream exists;
- bounded branch count/byte limits truncate safely with explicit metadata;
- non-repo, nested-repo misuse, missing trusted metadata, and path traversal
  reject consistently with existing Git read operations;
- branch names with unusual but valid ref characters are escaped/serialized
  safely;
- static/provider guards expose only the branch inventory operation while still
  rejecting `git_checkout`, `git_branch_delete`, `git_branch_rename`,
  `git_merge`, `git_rebase`, `git_reset`, `git_push`, `git_pull`,
  `git_fetch`, `git_stash`, `git_clean`, `git_revert`, and `git_cherry_pick`;
- no resource schema is added unless the implementation deliberately adds a
  resource-backed observation record.

Non-goals:

- no branch creation beyond accepted `git_branch_start`;
- no arbitrary checkout or switching to an existing branch;
- no branch deletion, rename, upstream setup, default branch policy, or cleanup
  automation;
- no merge, rebase, reset, revert, cherry-pick, stash, clean, fetch, pull,
  push, remote configuration, PR handoff, or conflict workflow;
- no worktree graph resources, repository import/tree/history UI, native iOS
  SourceChanges UI, public `/engine` expansion, or production deployment
  behavior.

Docs/static updates:

- README capability table and Git/source-control paragraph if a new operation
  is exposed;
- `domains/git/mod.rs` progressive disclosure docs;
- Phase 2 scorecard/evidence/inventory/TSV;
- provider static guards and BPRC/HRA/TMB/TPC/PCC inventory guards only if the
  implementation changes their covered path sets.

Validation commands:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`;
- `cargo check --manifest-path packages/agent/Cargo.toml`;
- `cargo test --manifest-path packages/agent/Cargo.toml git_branch -- --nocapture`
  or the narrowest branch-inventory test filter added by the implementation;
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`;
- touched static/inventory invariant tests, especially BPRC, HRA, TMB, TPC,
  PCC, DRC, DESI, and SACB when their inputs change;
- `git diff --check`;
- `scripts/personal-info-guard.sh`.

iOS validation: no native SourceChanges UI is part of Slice 6E. Run iOS tests
only if generic runtime/resource rendering changes.

Residual user decisions after Slice 6E: push/PR approval, arbitrary checkout
policy, branch deletion/rename policy, default branch naming/cleanup policy,
native source-control UI scope, and conflict-resolution delegation.

#### Accepted Slice 6E Implementation

Implementation branch: `codex/phase-2-slice-6e-branch-inventory-v2`.
Implementation baseline:
`origin/main@2241def83033d3bb49836b0d6b1ecf3c36fc8c39`
(`docs: shape slice 6e branch inventory handoff`).
Accepted commits:

- `7f72e9407bf1dfc39b9a41dd091fc7fd7565d432` (`feat: add git branch inventory foundation`);
- `16025248d4b9f470786e61888d5f74b7fc9f3572` (`Fix truncated branch metadata inventory evidence`).

Review/fix loop:

- Initial independent review thread `019efa73-0911-7bc2-a10c-37be6ab374d9`
  returned `changes required` for an oversized metadata truncation path that
  could fail the whole inventory operation.
- Focused fix thread `019efa76-51cd-7902-8fca-aed5bb3487f9` added bounded
  partial-row handling, README/module docs, and an oversized-author regression.
- Final independent re-review thread `019efa7c-7bb9-7803-bf80-224f8b799c1b`
  returned `slice accepted` with no findings.

Accepted scope:

- Adds execute-only `git_branch_inventory`; no direct `git::branch_inventory`
  catalog contract and no durable resource kind.
- Keeps implementation under `packages/agent/src/domains/git/` with a
  `branch_inventory` module plus `capability::execute` adapter/schema and
  provider instruction updates.
- Resolves trusted working-directory metadata through existing Git service
  helpers and rejects traversal, non-repo paths, and nested-repo misuse.
- Enumerates sorted local `refs/heads/*`, reports current branch or detached
  `HEAD`, branch ref/name/OID rows, optional local upstream/ahead-behind
  evidence, bounded last-commit subject/time/author metadata, oversized
  metadata rows as truncated evidence, and explicit branch count/byte
  truncation metadata.
- Uses local non-paged Git commands only; it does not fetch, pull, push, switch,
  create, delete, rename, merge, rebase, reset, stash, clean, create worktrees,
  mutate the index, or edit worktree files.

Implementation and review validation:

- `cargo test --manifest-path packages/agent/Cargo.toml git_branch_inventory -- --nocapture`
  passed with seven focused tests after the fix, including deterministic
  order/current marker, detached `HEAD`, upstream/no-upstream, count/byte
  bounds, unusual branch name serialization, oversized metadata truncation,
  bad path/repo rejection, and execute-boundary coverage.
- `cargo check --manifest-path packages/agent/Cargo.toml`, `cargo fmt
  --manifest-path packages/agent/Cargo.toml --all -- --check`, `git diff
  --check`, and `scripts/personal-info-guard.sh` passed on the implementation
  branch and in independent review.
- The final review also ran the baseline closure, HRA, true modularity, true
  primitive cleanup, primitive code cleanup, security authority/capability
  boundary, and documentation/evidence scorecard invariant targets.

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

#### Selected Slice 7A Discovery Packet

Exact next slice to implement: **Slice 7A: Goal And Question Foundation**.

Why this is the smallest safe Slice 7 cut: current main already has engine
queues, streams, generic resources, approval/freshness evidence, memory trace
refs, and replay rows. It does not have a package that owns durable user goals,
question prompts, answer provenance, or the relationship between goal state and
queue evidence. Implementing those records first gives users and agents real
inspectable work/question objects without restoring the old prompt queue,
autonomous planner, inbox product, subagent orchestration, scheduler, or native
iOS Work dashboard in one step.

First-principles UX review:

- Users should be able to ask "what work is pending?", "what question blocked
  this goal?", and "what answer was used?" from server truth rather than from
  chat transcript inference.
- The first cut should be useful through `execute` and generic runtime/resource
  rendering: create/list/inspect/cancel goals, create/list/inspect/answer
  questions, and see bounded queue/resource refs.
- Old `agent::run_goal`, prompt queues, work snapshots, ask-user pause planes,
  and answer submission DTOs are evidence only. They do not authorize copying
  old APIs or fixed iOS panels.

Architecture review:

- Core primitives: reuse existing engine queues, resources, streams,
  idempotency ledger, approvals, memory trace refs, and replay. Do not add a
  new public engine primitive unless implementation proves a generic substrate
  gap shared by multiple packages.
- Modular owner: add a `goal_question` or similarly named domain/package that
  owns goal lifecycle, question lifecycle, answer idempotency, plan/evidence
  refs, queue refs, stream payloads, and package docs/tests.
- Resource shape: reuse the existing generic `goal` resource kind where it is
  sufficient, then add only missing package-owned resource definitions such as
  `user_question`, `goal_plan`, or `goal_answer` if the generic resource schema
  cannot encode lifecycle, expiry, answer provenance, and replay refs safely.
- Provider surface: expose only operation values behind
  `capability::execute`, for example `goal_create`, `goal_list`,
  `goal_inspect`, `goal_cancel`, `question_create`, `question_list`,
  `question_inspect`, and `question_answer`. Direct `goal::*` catalog
  functions may exist for backend/domain contracts, but model access remains
  the single `execute` primitive.
- Queue boundary: Slice 7A may enqueue or record queue refs only when the
  queue item points at an explicitly scoped domain function with durable
  receipt evidence. It must not start autonomous multi-turn execution,
  scheduler-driven runs, subagents, or hidden prompt queues.
- Authority boundary: mutating goal/question operations require explicit
  idempotency and least-privilege grants. Answers must record actor, expected
  question version, freshness/expiry outcome, trace refs, replay refs, and
  whether the answer unblocks a goal; answer records do not mint authority.
- Memory boundary: goal/question records may carry memory trace refs and
  selected context refs, but Slice 7A must not add semantic retrieval,
  automatic retention, procedural memory, or hidden prompt memory behavior.
- iOS boundary: no native Work dashboard or question sheet in Slice 7A. iOS
  remains generic runtime/resource rendering unless implementation touches
  protocol DTOs for server-fact display, in which case focused decode and
  projection tests are required.

Exact implementation scope:

- Add the backend domain contract, handler table, service, support/types, and
  resource definitions needed for durable goal/question lifecycle.
- Support create/list/inspect/cancel for goals with explicit objective,
  status, owner/session/workspace scope, success criteria, constraints, queue
  refs, plan/evidence refs, cancellation reason, trace refs, replay refs, and
  revision.
- Support create/list/inspect/answer for user questions with prompt text,
  requester/goal refs, answer options or free-form allowance, expiry, pending/
  answered/expired/cancelled state, expected-version idempotent answers,
  answer actor/provenance, trace refs, replay refs, and lifecycle stream
  evidence.
- Add bounded model-visible `execute` operation results and schema/static guards
  proving the provider-visible tool remains singular.
- Add deterministic tests for resource schemas, lifecycle transitions,
  idempotent replay, expected-version conflicts, expiry/fail-closed answer
  handling, scope isolation, queue ref persistence, stream publication, replay
  refs, and provider execute routing.

Explicit non-goals:

- no autonomous goal runner, planner, task decomposition engine, hidden prompt
  queue, background scheduler, reminders, notifications, inbox delivery, APNs,
  subagents, web research, Git behavior, filesystem behavior, semantic memory,
  native iOS Work dashboard, native question sheet, new public `/engine` goal
  APIs, settings/profile fields, database tables outside the resource/stream/
  queue substrate, production deployment behavior, or copied historical DTOs.

Likely files and boundaries:

- `packages/agent/src/domains/goals/` or
  `packages/agent/src/domains/goal_question/`
- `packages/agent/src/domains/mod.rs`
- `packages/agent/src/domains/registration/catalog.rs`
- `packages/agent/src/domains/capability/contract.rs`
- `packages/agent/src/domains/capability/operations/mod.rs`
- `packages/agent/src/engine/durability/resources/definitions.rs`
- optional focused split such as
  `packages/agent/src/engine/durability/resources/goal_definitions.rs`
- `packages/agent/tests/*_invariants.rs` inventories and static guards for
  BPRC, HRA, TMB, TPC, PCC, SACB, CSD, DESI, and iOS affordance boundaries as
  touched
- `README.md`
- `packages/agent/docs/phase-2-agent-execution-restoration-*`
- `packages/ios-app/docs/architecture.md` only if Swift/iOS-facing protocol or
  generic runtime display claims change

Deterministic validation gates:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
- `cargo check --manifest-path packages/agent/Cargo.toml`
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::goals -- --nocapture`
  or the exact chosen domain test filter
- `cargo test --manifest-path packages/agent/Cargo.toml --lib domains::capability -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test true_modularity_boundary_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture`
- `cargo test --manifest-path packages/agent/Cargo.toml --test ios_affordance_restoration_map_invariants -- --nocapture`
- `scripts/personal-info-guard.sh`
- `git diff --check`
- `git ls-files -ci --exclude-standard`
- If Swift files change: `cd packages/ios-app && xcodegen generate`, plus
  focused iOS DTO/view-model tests for the touched generic runtime path.

Docs/static updates required:

- README capability/domain/resource/event sections for the new execute
  operations, domain registration, resource kinds, lifecycle stream, and
  explicit iOS non-goal.
- Domain `mod.rs` progressive docs for the new package and any touched resource
  kernel split.
- Phase 2 scorecard, evidence manifest, inventory narrative, and TSV row
  `P2AER-INV-010`.
- Static inventory rows and source guards for BPRC, HRA, TMB, TPC, PCC, SACB,
  CSD, DESI, and IARM as required by the touched files.

Residual risks and deferred work:

- The generic built-in `goal` resource kind is broad and may need package-owned
  lifecycle constraints to avoid schema drift or ambiguous ownership.
- Queue-backed autonomous execution needs a later grant/runner design; Slice 7A
  should preserve queue receipt evidence without running hidden work loops.
- Question interruption policy, notification delivery, native iOS question UI,
  and Work dashboard placement remain user decisions after the backend
  contract exists.
- Expiry and cancellation must be deterministic and testable without wall-clock
  race assumptions; prefer injectable time seams in the domain service.

Accepted implementation status:

- Branch `codex/phase-2-slice-7a-goal-question-foundation-v2` from
  `origin/main@9950ea484299901e09af9077f33466021118ca33` implements the
  accepted Slice 7A foundation.
- Accepted commits are `22ff03e89`, `17a6869c9`, `5826fb787`, `4a9454e53`,
  `6915bcfcd`, `b96494d89`, and `4ecb61261`.
- Accepted scope adds `domains/goals`, execute-only goal/question operation
  adapters, `user_question` and `goal_answer` resource definitions, and a
  narrowed generic `goal` resource schema using existing resources, streams,
  traces, replay refs, and execute idempotency.
- Accepted operations are `goal_create`, `goal_list`, `goal_inspect`,
  `goal_cancel`, `question_create`, `question_list`, `question_inspect`, and
  `question_answer`.
- Accepted evidence covers create/list/inspect/cancel goal behavior,
  create/list/inspect/answer question behavior, bounded list truncation,
  scope isolation, expiry/stale-version/malformed-input fail-closed paths,
  answer reason/authority/freshness/idempotency provenance, and replaying the
  same answer idempotency key without double-answering.
- Review/fix loop: review `019efabf-6f5b-76b0-951b-13e28ae785f4` led to
  resource authority hardening; review `019eface-a421-7271-b688-f5250066cf26`
  found the missing HRA inventory row for
  `engine/tests/authority/execute_goal_authorization.rs`; final review
  `019efad9-68bb-7ab0-9933-df140600ebed` accepted the slice with no blocking
  findings.
- Status is accepted mainline baseline after mainline closeout validation.

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

#### Slice 8A Accepted Implementation: Web Fetch And Source Provenance Foundation

Implementation branch:
`codex/phase-2-slice-8a-web-fetch-source-provenance`.
Baseline:
`origin/main@49a47cc1902a958eb775bcb5a3a28913d0d3aefb`
(`docs: accept phase 2 slice 7a`).
Accepted commits:
`f5b0bb0895f9f829541bfa426453b59cf0a401cd`,
`37e835d7b575ef3b4063a5c0da0b050fd6f8b192`, and
`77f0620545b4d277c0288cc9503e2d90cdf7e0b8`.

Accepted scope:

- Add `domains/web` as the package owner for direct URL fetch source
  provenance, without adding public `web::*` catalog functions.
- Expose exactly one new provider-visible operation value behind
  `capability::execute`: `web_fetch`.
- Require trusted agent/system runtime context, current session, idempotency,
  `web_source` resource authority, and `networkPolicy: declared` before any
  network I/O. `networkPolicy: none` remains the default for all other execute
  operations and fails closed for `web_fetch`.
- Create idempotent `web_source` resource/cache evidence with URL/final URL,
  fetched-at time, status, content type, byte/hash evidence, redaction and
  truncation metadata, trace refs, replay refs, authority refs, and
  `web.lifecycle` stream evidence.
- Bound URL length, redirect count, response bytes, output text bytes, timeout,
  content-type handling, and error details.
- Reject unsupported schemes, credentials in URLs, URL fragments, malformed or
  overlong URLs, and unsafe local/internal targets except deterministic HTTP
  loopback test targets.

Non-goals:

- No search provider, browser automation, crawling, sitemap traversal, robots
  policy engine, login/cookies/session reuse, credential handling, shell/process
  network side channel, native iOS web UI, public `/engine` expansion, or
  network-enabled `job_*` behavior.

Accepted validation:

- Focused web-domain tests cover declared-network authority denial, successful
  deterministic loopback fetch, URL validation, redirects/final URL evidence,
  byte/output truncation, content-type handling, redaction, hash/source
  evidence, unsafe IPv4/IPv6 and DNS-result rejection, and idempotent replay
  without duplicate durable evidence.
- Capability schema tests cover `web_fetch` exposure and reject non-goal names
  such as `web_search`, `browser_open`, `browser_click`, `web_crawl`,
  `web_login`, and network-enabled `job_*` variants.
- Initial review found redirect-target validation and DNS/internal-IP gaps plus
  README acceptance wording; focused fix `37e835d7` added redirect validation
  before follow, resolver filtering, and candidate-scoped docs.
- Re-review found IPv6 site-local/IPv4-compatible edge gaps and missing
  `network_policy.rs` static inventory rows; focused fix `77f06205` added
  deterministic regressions and inventory coverage.
- Final independent re-review `019efb3c-e2b3-7950-b1f6-56cc884c509e`
  returned `slice accepted` with no findings.

#### Slice 8B Accepted Implementation: Web Source Citation And Inspection Foundation

Implementation branch:
`codex/phase-2-slice-8b-web-source-citation-inspection`.
Baseline:
`origin/main@d2cb7cd32976f1de460defe5fc0cb094669b0140`
(`docs: accept phase 2 slice 8a`).
Accepted commit:
`8033e22932f55388a94f9d18ce6b11a91f9f1545`
(`feat: add web source citation inspection`).

Accepted scope:

- Add execute-only `web_source_list` and `web_source_inspect` operation values
  behind the single provider-visible `capability::execute` primitive.
- Add `domains/web/source.rs` as the read-only source inspection owner for
  bounded citation fields from durable `web_source` resource payloads.
- Return requested URL, final URL, fetched time, status, content type,
  captured SHA-256, captured/output byte counts, truncation/redaction metadata,
  redacted snippets, trace refs, replay refs, and resource refs.
- Require trusted current-session context plus `web.read` and `resource.read`
  authority before returning source details.
- Reject malformed ids, wrong resource kind/schema, missing current versions,
  missing or stale requested versions, cross-session scope mismatches, and
  missing read authority.
- Keep read operations valid under `networkPolicy: none`; `web_fetch` remains
  the only network operation and still requires declared network authority.

Non-goals:

- No search provider, browser automation, crawling, sitemap traversal, robots
  policy engine, login/cookies/session reuse, credential handling,
  shell/process network side channel, native iOS source UI, public `/engine`
  expansion, or network-enabled `job_*` behavior.

Accepted validation:

- Implementation validation passed `cargo fmt`, `cargo check`, focused
  `domains::web`, `domains::capability`, and OpenAI message-converter tests,
  SACB/HRA/TMB/TPC/PCC/BPRC/IARM/DESI/public-protocol static guards,
  `git diff --check`, `git ls-files -ci --exclude-standard`, and
  `scripts/personal-info-guard.sh`.
- Independent review thread `019efb6e-dfc0-7b73-8bd6-d23f91e82248` verified the
  expected head, baseline ancestry, read authority, scope/version rejection,
  no-network read behavior, provider operation exposure, static inventories,
  and personal-info guard, then returned `slice accepted` with no findings.

#### Accepted Slice 8C: Web HTML/Text Extraction And Citation Quality Foundation

Implementation branch:
`codex/phase-2-slice-8c-web-html-text-extraction`.
Fix branch:
`codex/phase-2-slice-8c-web-html-text-extraction-fix1`.
Baseline:
`origin/main@5c99501b5e00305f3be95ae3fce4d2f855c6aed8`
(`docs: accept phase 2 slice 8b`).
Accepted implementation commit:
`ea4a4d04ceb37a10899871c3fe4f394ae10fbfa5`
(`feat: add web html text extraction`).
Accepted fix commit:
`5e881e8681229545fe8260a1dc2be8f47cd07a3a`
(`fix: sanitize web html titles`).

Accepted scope:

- Keep the provider-visible web operation set unchanged:
  `web_fetch`, `web_source_list`, and `web_source_inspect`.
- Add `domains/web/extract.rs` as the deterministic HTML/XHTML readable-text
  extraction owner inside the existing web boundary.
- For HTML-like content types, derive readable text and safe title metadata from
  captured bytes before output bounding, redaction, and snippet generation.
- Preserve captured raw response bytes, raw byte counts, and raw captured-byte
  SHA-256 evidence as the durable source provenance hash.
- Add backward-compatible `textEvidence` extraction metadata for mode,
  extractor id/version, title, extracted text bytes, max output bytes, and
  truncation flags.
- Keep source list/inspect read-only, valid under `networkPolicy: none`, and
  compatible with pre-Slice-8C `web_source` records that lack extraction
  metadata.

Accepted non-goals:

- No `web_search`, search provider, browser automation/control, crawling,
  sitemap traversal, robots policy engine, login/cookies/session reuse,
  credential reuse, shell/process network side channel, network-enabled jobs,
  public `/engine` web APIs, native iOS source UI, or specialized source
  rendering.

Accepted validation:

- Focused web tests cover deterministic HTML extraction, script/style/noise
  removal, redaction after extraction, plain text/JSON/XML/binary/malformed
  HTML/oversized/non-UTF8 paths, idempotent replay stability, and old
  Slice 8A/8B source inspection compatibility.
- Fix validation added coverage that safe titles are bounded/redacted in the
  fetch result JSON, stored resource payload, source inspect, and source list
  surfaces.
- Implementation and re-review validation passed `cargo fmt`, `cargo check`,
  focused `domains::web`, HRA/TMB/TPC/PCC/SACB/BPRC/IARM/DESI/public-protocol
  static guards, `scripts/personal-info-guard.sh`, `git diff --check`, and
  ignored-file audit.
- Initial review thread `019efb99-ee44-7901-b70a-56ea4643f302` required changes
  for unsafe title metadata and missing HRA ownership-map coverage. Re-review
  thread `019efbac-4560-7382-a034-4ef36854367f` verified both fixes and
  returned `slice accepted`.

#### Accepted Slice 8D: Web Source Retention And Cache Policy Foundation

Implementation branch:
`codex/phase-2-slice-8d-web-source-retention-cache-policy`.
Baseline:
`origin/main@8ed8db55500f3a05aef55a1e2ec39acba30a8c07`
(`docs: accept phase 2 slice 8c`).
Accepted implementation commit:
`3a9d4f35674b166528d7e15aea0e17802d634cea`
(`feat: add web source archive lifecycle`).
Implementation thread:
`019efbbd-f745-7752-8cd8-fdd86194d138`.
Independent review thread:
`019efbd4-b199-71c2-b56d-4d8c7aa02976`.
Status:
`accepted`.

Accepted scope:

- Add execute-only `web_source_archive` behind the existing
  `capability::execute` primitive.
- Archive only current-session `web_source` resources after trusted runtime
  context, `web.read`, `web.write`, `resource.read`, `resource.write`,
  `kind:web_source`, stable `idempotencyKey`, bounded non-empty `reason`, and
  `expectedWebSourceVersionId` checks.
- Append an archived resource version/lifecycle update with archive metadata
  while preserving source payload, byte/text evidence, provenance, trace refs,
  replay refs, and resource version history.
- Make `web_source_list` default to active/fetched records only and include
  archived records only with explicit `includeArchived`.
- Keep `web_source_inspect` able to inspect exact archived source records for
  replay/citation audit.
- Keep archive/list/inspect valid only under `networkPolicy: none` with no HTTP
  client construction or network I/O.

Accepted non-goals:

- No `web_search`, search provider, browser automation/control, crawling,
  sitemap traversal, robots policy engine, login/cookies/session reuse,
  credential reuse, shell/process network side channel, network-enabled jobs,
  public `/engine` web APIs, native iOS source UI, deletion/erasure/pruning,
  automatic TTL cleanup, settings/profile fields, or database migrations.

Accepted validation:

- Focused web tests cover successful archive preservation, stale CAS denial,
  wrong kind/scope denial, missing authority denial before mutation,
  idempotency replay without duplicate archive versions, default list filtering,
  explicit archived inclusion, exact archived inspection, and no-network
  archive/list/inspect behavior.
- Capability/provider tests cover `web_source_archive`,
  `expectedWebSourceVersionId`, `includeArchived`, and continued rejection of
  search/browser/crawl/login/network-job non-goals.
- HRA/TMB/TPC/PCC/SACB inventories classify the new archive implementation and
  test files as accepted Slice 8D surfaces.
- Independent review passed `cargo fmt`, `cargo check`, focused `domains::web`,
  `domains::capability`, OpenAI message-converter tests, HRA/TMB/TPC/PCC/SACB/
  BPRC/IARM/DESI/public-protocol static guards, `scripts/personal-info-guard.sh`,
  `git diff --check`, and ignored-file audit, then returned `slice accepted`.

#### Slice 8E Accepted: Web Robots Policy Foundation

Implementation branch:
`codex/phase-2-slice-8e-web-robots-policy`.
Accepted fix branch:
`codex/phase-2-slice-8e-web-robots-policy-fix2`.
Baseline:
`origin/main@9a74084d9ce8b241d8fdf4a7865a683bd04e652c`
(`docs: accept phase 2 slice 8d`).
Status:
`accepted`.

Accepted scope:

- Add execute-only `web_robots_check` behind the existing
  `capability::execute` primitive.
- Fetch only one requested origin's `robots.txt` after trusted current-session
  context, stable `idempotencyKey`, `networkPolicy: declared`, `web.write`,
  `resource.read`, `resource.write`, `kind:web_robots_policy`, and existing
  URL/redirect/DNS safety checks.
- Add `domains/web/robots/mod.rs` as the web-owned robots policy module with a
  deterministic tolerant parser, matched user-agent selection, allow/deny
  decision, relevant matched rule, bounded body metadata, captured-byte
  SHA-256, parser id/version, authority refs, trace/replay refs, and
  idempotency/cache refs.
- Add engine-owned `web_robots_policy` resource definitions for append-only
  checked evidence.
- Record sitemap lines as metadata only and never traverse them.
- Keep `web_fetch`, `web_source_list`, `web_source_inspect`, and
  `web_source_archive` behavior compatible.
- Keep production robots fetches HTTPS-only, with HTTP loopback available only
  through explicit test-only fixtures.

Accepted non-goals:

- No `web_search`, search provider API, crawling, sitemap traversal, browser
  automation/control, login/cookies/session reuse, credential reuse, public
  `/engine` web APIs, native iOS source UI, deletion/pruning/TTL cleanup,
  settings/profile fields, database migrations, or network-enabled jobs.

Accepted validation:

- Focused web tests cover allow/deny decisions, matched user-agent/rule
  evidence, missing/malformed/oversized body behavior, bounded/truncated
  output, sitemap metadata-only recording, authority failures before network
  I/O, unsafe initial URL/redirect/DNS rejection, and idempotent resource
  replay without duplicate evidence.
- Capability/provider tests cover `web_robots_check` exposure through the
  single execute primitive and continued rejection of search/browser/crawl/
  login/network-job non-goals.
- HRA/TMB/TPC/PCC/SACB inventories classify the new robots implementation and
  test files as accepted Slice 8E surfaces.
- Independent review/fix loop required production HTTP loopback rejection, TPC
  file-budget splitting, and `resource.read` authority before robots
  cache/evidence reads. Fix commits
  `b0352fbb79f30b267d8725deaf3fc2e234ec5998` and
  `21d3d24a7f757b43d3f51599fe35a14e7f0f3633` addressed those findings, and
  final re-review thread `019efc26-2fca-7dc3-abf2-c8d1dbab81b5` returned
  `slice accepted`.

#### Slice 8F Accepted: Web Fetch Robots Evidence Linkage Foundation

Implementation branch:
`codex/phase-2-slice-8f-web-fetch-robots-evidence-linkage`; accepted fixed
branch `codex/phase-2-slice-8f-web-fetch-robots-evidence-linkage-fix1`.
Baseline:
`origin/main@419433985790f35f5ef514e9f508b4f8906d37a1`
(`docs: accept phase 2 slice 8e`).
Source handoff thread:
`019ef914-ed80-78f2-b253-229240d49444`.
Discovery thread:
`019efc32-30b1-7811-9959-7e539ba8062f`.
Implementation thread:
`019efc38-4532-7d02-97d2-67149b834f76`.
First review thread:
`019efc5c-dead-76c0-8cb3-496dba956a06`.
Focused fix thread:
`019efc66-358e-7571-8508-6e691c663e49`.
Accepting re-review thread:
`019efc78-a769-76a0-97fe-e75601b0955a`.
Status:
`accepted`.
Accepted commits:
`c01924ba634b64ec0bdb6033bd53dc304b5a94fc` and
`cb30347b29d7e11d8e0e4210068ee67e6cabd9f0`.

Accepted scope:

- Keep provider-visible access behind the existing `capability::execute`
  primitive and the existing `web_fetch` operation.
- Add optional `web_fetch` inputs `webRobotsPolicyResourceId` and
  `expectedWebRobotsPolicyVersionId`; both are required together and default
  non-robots `web_fetch` behavior remains compatible.
- When the pair is supplied, validate the current-session `web_robots_policy`
  resource before target HTTP client construction or target network I/O.
- Fail closed for missing, unreadable, wrong-kind/schema, wrong-session,
  missing-current-version, stale expected version, malformed payload, origin or
  target URL mismatch, non-`allow` decision, and insufficient robots-policy
  grant authority.
- Validate exact target identity with a non-displayed canonical target
  fingerprint while keeping provider-visible target URLs sanitized.
- Persist bounded `robotsPolicyRefs` on resulting `web_source` payloads and
  expose those refs through `web_source_list` and `web_source_inspect` without
  robots body previews, body evidence, or sitemap content.
- Derive and authorize robots-linked fetch grants with `web.read`,
  `resource.read`, `kind:web_robots_policy`, and existing source write grants
  only when both robots evidence fields are non-empty strings; explicit JSON
  null fields preserve ordinary non-robots fetch semantics.

Accepted non-goals:

- No `web_search`, browser automation, crawling, sitemap traversal/fetching,
  login/cookies/session reuse, public `/engine` web API expansion, native iOS
  source UI, settings/profile changes, database migrations, deletion/pruning/
  TTL cleanup, network jobs, or global robots requirement.

Validation evidence:

- Focused web tests cover allow-linked fetch success, deny/malformed/stale/
  wrong-kind/wrong-session/wrong-version/non-current/target/origin mismatch
  denial before target network I/O, sensitive-query exact-target fingerprint
  mismatch, default non-robots compatibility, explicit null robots fields, and
  bounded refs in source list/inspect.
- Capability, runtime grant, engine authorization, and OpenAI converter tests
  cover the optional execute schema/guidance and least-privilege grant shape.
- HRA/TMB/TPC/PCC/SACB/BPRC/IARM/DESI/public-protocol static gates classify the
  accepted implementation surfaces.
- First review required exact target matching beyond sanitized URL comparison
  and null-field grant hardening. Focused fix commit
  `cb30347b29d7e11d8e0e4210068ee67e6cabd9f0` addressed both; accepting
  re-review thread `019efc78-a769-76a0-97fe-e75601b0955a` returned no
  findings.

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

Slice 10A accepted scope: establish only the inert task lifecycle foundation:
`subagent_task` resources, trusted internal create/update service functions,
and read-only `subagent_task_list`/`subagent_task_inspect` execute operations.
It deliberately excludes actual child-agent spawn, worker/package launch,
job/process start, tool execution, scheduling, real cancellation, result merge,
native fixed UI, settings/profile changes, migrations, and public `/engine`
expansion.

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
auditable procedural state. Slice 11A starts with read-only custody and
inspection only.

User-facing outcome: users can inspect active procedures, rules, hooks, skills,
eval status, provenance, and disable/edit/delete them.

Slice 11A user-facing outcome: providers can list/inspect bounded redacted
skill/rule/hook/procedure provenance, eval, status, and refs for current
session/workspace resources through `capability::execute`; no active procedure
execution, disable/edit/delete, trigger firing, or prompt inclusion is restored.

True primitives: memory contract, resource kernel, eval resources, trigger
substrate, approvals, and context inclusion trace.

Modular boundaries: procedural package owns skill/rule/hook/procedure records
and future activation policy. Slice 11A owns only inert `procedural_record`
resource schemas plus bounded projections. It does not recreate
`packages/agent/skills/`, skill-copy wiring, or bootstrap prompt injection.

Likely files/areas: memory resources, trigger runtime, future
`domains/procedural`, context assembly, iOS memory/procedure audit.

Slice 11A files/areas: `domains/procedural`, `capability::execute` operation
adapters/schema guidance, engine resource definitions, provider message
converter guidance, Phase 2 docs, README, and static inventories.

Old evidence paths: `BPRC-FEATURE-10`, `IARM-SURFACE-021`,
`IARM-SURFACE-034`, feature index section 10.

Acceptance criteria: every active procedure has provenance, lineage, evals,
scope, trigger, prompt-inclusion reason, rollback, and disable behavior.

Focused tests: activation/deactivation, trigger policy, eval pass/fail,
context inclusion, deletion, SSARR no repo-managed skills guard. Slice 11A
focused tests instead prove list/inspect success and denial cases, projection
redaction/bounds, provider-visible read-only schema, runtime/pre-handler grants,
and absence of repo-managed skills, skill-copy wiring, activation, trigger,
install, execution, autonomous, and prompt-injection surfaces.

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

Implementation status: Accepted Slice 12 adds durable `schedule` and
`schedule_run` resources, `domains/scheduler`, execute-only
`schedule_create`, `schedule_list`, `schedule_inspect`, `schedule_cancel`, and
`schedule_fire_due`, explicit non-wildcard target selectors, authority records,
resource leases during due evaluation, deterministic clock-injection tests,
explicit provider-visible `evaluationAt`, missed-run skip/catch-up/fire-once policy,
cancellation terminality,
retention/bounded projections, and `scheduler.lifecycle` evidence. This slice
does not add hidden cron loops, direct feature execution, APNs/device
notification delivery, public scheduler APIs, native fixed schedule UI,
autonomous planning, or result merge.

### Slice 13: Notifications, APNs, Device Broker, And Inbox

Implementation status: Accepted Slice 13 backend foundation is current baseline.
Accepted Slice 13 adds server-owned `domains/device` and `domains/notifications`,
durable `device_registration`, `notification`, and `notification_delivery` resource
schemas, lifecycle stream evidence, and execute-only operation values through
the existing `capability::execute` primitive. It deliberately does not add live
APNs sends, APNs entitlements, native iOS inbox/deep links, public
notification APIs, or client-local inbox state.

Objective: restore notification delivery only after server-owned device and
notification resources exist.

User-facing outcome: the server can durably register device metadata, create
and read notification inbox resources through execute operations, mark records
read, inspect delivery evidence, and compute badge counts for later UI/APNs
slices. Users do not yet receive live push notifications or open a native inbox
in this slice.

True primitives: device resource, notification resource, delivery event,
per-device token custody, approval/user-attention policy, and APNs transport
boundary.

Modular boundaries: notification/device package owns APNs registration,
delivery, read state, token invalidation, retention, and privacy. iOS owns
permission prompts and local presentation only.

Files/areas implemented: `domains/device`, `domains/notifications`, built-in
resource definitions, capability execute adapters, runtime grant narrowing,
provider schema/instruction text, BPRC/IARM guards, README, and this Phase 2
inventory. Platform APNs, iOS app delegate/entitlements/inbox, and physical
push validation remain later slices after backend proof.

Old evidence paths: `BPRC-FEATURE-12`, `IARM-SURFACE-019`,
`IARM-SURFACE-033`, Phase 1 Slice 6 progress ledger.

Acceptance criteria: no fake local inbox; device tokens are secret; APNs
environment is explicit; delivery/read state is durable; badge semantics are
defined; source-control/process/job/subagent/approval/web/research/skills/rules
memory notification families map to real events.

Focused tests: device register/unregister, token redaction, delivery failure
evidence, read state, badge semantics, retention defaults, APNs environment,
authority/resource checks, scope isolation, replay refs, provider schema
behavior, runtime grant narrowing, and iOS/APNs absence guards.

iOS validation: not run for Slice 13 because no Swift source, APNs entitlement,
permission prompt, native inbox UI, or live APNs transport was added. Physical
device APNs validation is required only for a later live transport/native UI
slice.

Docs/static updates: README capabilities/settings/database, iOS architecture,
privacy, entitlements, SACB inventory.

User decisions: live APNs provider credentials, native inbox/deep-link UX,
which events notify by default beyond the server foundation, and any retention
policy tighter than the current 90-day/500-record defaults.

### Slice 14: Media, Voice Notes, Imports, Repository Trees, And System Updates

Implementation status: Accepted Slice 14A media artifact and voice-note
resource foundation and accepted Slice 14B import/session-resource graph
foundation are current baseline. Accepted Slice 14C update diagnostics is also
current baseline. Accepted Slice 14D repository-tree snapshot metadata is also
current baseline. Accepted Slice 14E import-preview metadata is also current
baseline. Slice 14 remains split because media, imports, repository trees, and
system updates are separate families.

Objective: restore lower-priority product surfaces only after the core
agent-execution patterns are proven.

User-facing outcome: Slice 14A gives the backend a durable place to hold
voice/media artifact metadata and blob refs. Slice 14B gives the
backend a durable place to hold generic session/resource import lineage
metadata without exposing raw import payloads or repository trees. Import
previews, session tree/history views, repository divergence, update
installer/restart flows, deploy automation, live production update checks,
native update panels, and native media UX remain later work. Slice 14C only
adds backend metadata custody for signed-release/update diagnostic evidence.
Slice 14D only adds backend metadata custody for content-free repository-tree
snapshot evidence. Slice 14E only adds backend metadata custody for
content-free import-preview evidence.

True primitives: artifact resources, storage refs, replay, settings parity,
approval, and package-specific events.

Modular boundaries: media package owns storage refs, bounded media metadata,
retention, redacted projections, lifecycle evidence, and local transcription
metadata. Import/history package owns generic graph lineage operations,
bounded import provenance metadata, redacted projections, and lifecycle
evidence. Repository-tree package owns content-free repository/root/head/tree
refs, bounded relative path metadata, redacted projections, and lifecycle
evidence; import execution and native tree rendering remain outside the
accepted scope. Import-preview package owns content-free links between
import-history and repository-tree refs, bounded preview metadata, redacted
projections, and lifecycle evidence; actual import execution and application
remain outside the accepted scope. Update package owns signed update checks and
never production deployment; accepted Slice 14C records bounded metadata only
and performs no live check, installation, restart, catalog registration, or
deployment.

Files/areas accepted for Slice 14A: `domains/media`, built-in
`media_artifact` resource definition, capability execute adapters, runtime
grant narrowing, provider schema/instruction text, README, and static
inventories. Slice 14B accepts `domains/import_history`, built-in
`import_history_record` resource definitions, execute adapters, runtime grant
narrowing, provider schema/instruction text, README, and static inventories.
Slice 14C accepts `domains/update_diagnostics`, built-in
`update_diagnostic_record` resource definition, execute adapters, runtime grant
narrowing, provider schema/instruction text, README, and static inventories.
Slice 14D accepts `domains/repository_tree`, built-in
`repository_tree_snapshot` resource definition, execute adapters, runtime
grant narrowing, provider schema/instruction text, README, and static
inventories. Slice 14E accepts `domains/import_preview`, built-in
`import_preview` resource definition, execute adapters, runtime grant
narrowing, provider schema/instruction text, README, and static inventories for
content-free preview metadata only. Future Slice 14 sub-slices still own actual
import execution/application, live update execution domains, and iOS native
surfaces only where generic UI is insufficient.
Accepted Slice 15A begins the separate program-execution row by adding
`domains/program_execution`, the built-in `program_execution_record` resource
definition, execute adapters, runtime grant narrowing, provider
schema/instruction text, README, and static inventories for metadata-only
program execution records. It deliberately excludes runtime execution,
subprocess/job launch, package installation, file writes, live network behavior,
notebook/PTY surfaces, result merge, and native UI.
Accepted Slice 16A begins the prompt-artifact row by adding
`domains/prompt_artifacts`, the built-in `prompt_artifact` resource
definition, execute adapters, runtime grant narrowing, provider
schema/instruction text, README, and static inventories for explicit opt-in
metadata-only prompt artifacts. It deliberately excludes raw prompt body
persistence, provider-visible raw prompt payloads, automatic prompt-history
capture, prompt injection/context inclusion, learned behavior, native
snippet/template UI, settings/profile migration, public prompt APIs, and
repo-managed skills.
Accepted Slice 17A begins the provider-reasoning row by adding metadata-only
provider reasoning/status evidence at the existing model/responder audit and
turn-persistence boundaries, typed assistant and stream payload support,
provider audit redaction hardening, README, and evidence/inventory updates. It
deliberately excludes hidden chain-of-thought exposure, invented reasoning
summaries, raw provider reasoning payload persistence, provider-visible raw
reasoning payloads, native reasoning UI, settings/profile migration, public
reasoning APIs, broad DTO resurrection, and unrelated DRC cleanup.
Accepted Slice 18A adds the memory query/decision evidence rows. It adds built-in
`memory_query` and `memory_decision` resource definitions, memory-domain
record/list/inspect functions, read-only provider-safe inspection through
`capability::execute`, resource/protocol DTOs, README, and static
inventory/evidence updates for metadata-only audit records. It also enforces
explicit memory/resource authority, resource-kind grants, and inspect-resource
selectors for the provider-visible reads after independent review found the
initial authority mapping incomplete. It deliberately excludes semantic/vector
retrieval, embeddings, reranking, summarization, episodic event-to-memory
conversion, prompt inclusion, automatic retention, native iOS UI, settings
profile migration, public `/engine` expansion, repo-managed skills, and
unrelated DRC cleanup.
Accepted Slice 19A closes the narrow backend portion of `P2AER-INV-020` /
`BPRC-FEATURE-20` / `BPRC-FEATURE-21`: Event Protocol Catalog Parity
Foundation. It keeps the generated persisted session event catalog unchanged
and adds source-backed parity evidence for the 24 typed primitive loop event
variants, README/progressive docs synchronization, allowed loop/protocol
domains, and retired product event rejection. It deliberately excludes new
event variants, product DTO resurrection, fixed iOS panels, public `/engine`
expansion, database migrations, settings/profile migration, runtime execution,
repo-managed skills, and unrelated DRC cleanup.
Accepted Slice 20A closes the narrow backend parity portion of `P2AER-INV-021`
/ `BPRC-FEATURE-22`: Database Schema Catalog Parity Foundation. It strengthens
the DSEMD static gate so the README Database Schema table catalog must match
active SQLite schema sources, records the existing `engine_stream_subscriptions`
stream table in README, and leaves migrations, compatibility readers, product
tables, settings/profile parity, dependency restoration, public `/engine` APIs,
iOS panels, runtime execution, and deploy flows out of scope until separately
selected and reviewed.
Accepted Slice 21A closes the narrow parity portion of `P2AER-INV-022` /
`BPRC-FEATURE-23`: Settings/Profile Catalog Parity Foundation. It strengthens
the CPE static gate so the root README Key Configuration catalog must match
source-backed settings defaults and so every current iOS user-editable server
setting has decode, update, state, UI, and parity-test coverage. It fixes README
drift for `retry.maxRetries` and leaves new settings, profile migrations, broad
settings UI work, dependency restoration, fixed iOS panels, public `/engine`
expansion, runtime execution, repo-managed skills, and deploy/update flows out
of scope until separately selected and reviewed.

Old evidence paths: `BPRC-FEATURE-13`, `BPRC-FEATURE-16`,
`BPRC-FEATURE-18`, `BPRC-FEATURE-19`, `BPRC-FEATURE-20`,
`BPRC-FEATURE-21`, `BPRC-FEATURE-22`, `BPRC-FEATURE-23`,
`BPRC-FEATURE-24`, IARM media/session/system rows.

Acceptance criteria for Slice 14A: media resources store blob refs only, reject
raw bytes/base64, enforce MIME allow-list and size bounds, retain source and
evidence refs, record lifecycle/trace/replay refs, keep provider projections
redacted, require exact resource authority, and remain scoped to the current
session/workspace. Slice 14B stores bounded lineage refs only,
reject raw import payloads/repository trees/unsafe paths, require exact
`import_history_record` authority/selectors plus trusted current-session or
workspace scope, record lifecycle/trace/replay refs, keep provider
projections/redaction bounded, and use deterministic injected timestamps with
no import-history DRC finding. Slice 14C requires
bounded signed-release metadata only, exact `update_diagnostic_record`
authority/selectors, trusted current-session/workspace scope, lifecycle and
trace/replay evidence, redacted projections, fingerprinted idempotency
evidence, deterministic injected timestamps with no update-diagnostics DRC
finding, and no raw update/package/endpoint/command leakage. Broader Slice 14
accepted Slice 14D requires content-free `repository_tree_snapshot`
metadata only, exact `repository_tree_snapshot` authority/selectors, trusted
current-session/workspace scope, lifecycle and trace/replay evidence,
redacted projections, fingerprinted idempotency evidence, deterministic
injected timestamps with no repository-tree DRC finding, and no raw file
contents, blob bytes, absolute paths, repository visualization, import
preview/execute, native tree UI, or git mutation workflows. Accepted Slice 14E
requires content-free `import_preview` metadata only, exact
`import_preview` authority/selectors including `importPreviewResourceId`
scanner coverage, constrained import-history and repository-tree lineage refs,
trusted current-session/workspace scope, lifecycle and trace/replay evidence,
redacted projections, fingerprinted idempotency evidence, deterministic
injected timestamps with no import-preview or repository/import DRC finding,
and no raw import payloads, raw preview payloads, raw file contents, blob bytes,
raw repository contents, absolute paths, unsafe paths, import execution,
repository visualization, native import/tree UI, or git mutation workflows.
Broader Slice 14
acceptance still requires storage/migration/retention policy, settings parity,
event schemas, dependency review, iOS parity decision, and no deploy
automation.

Focused tests: Slice 14A covers media bounds, MIME validation, redaction,
retention, resource schema, lifecycle evidence, authority/scope isolation,
idempotency/replay refs, and no raw-audio/provider projection leaks. Slice 14B
covers import-history resource schema, authority/scope isolation,
bounded graph lineage projection, lifecycle evidence, idempotency fingerprint
redaction, deterministic timestamp handling, and no raw import/repository/path
leaks. Slice 14C tests cover update-diagnostic resource schema,
authority/scope isolation, bounded signed-release projections, lifecycle
evidence, idempotency fingerprint redaction, deterministic timestamp handling,
and no raw update/package/endpoint/command leakage. Slice 14D accepted
tests cover repository-tree resource schema, authority/scope isolation,
bounded content-free path metadata projections, path normalization/rejection,
lifecycle evidence, idempotency fingerprint redaction, deterministic timestamp
handling, and no raw content/path/authority leakage. Slice 14E accepted tests
cover import-preview resource schema, authority/scope isolation,
provider-visible bounded/redacted linked refs, path normalization/rejection,
wrong-kind and wrong-prefix lineage ref rejection, resource selector
enforcement, lifecycle evidence, idempotency fingerprint redaction,
deterministic timestamp handling, and no raw payload/content/path leakage.
Later Slice 14 sub-slices cover import execution, live update
execution, settings
parity, migration rollback, and iOS decoder tests.

iOS validation: not run for Slice 14A because no Swift source, native media
surface, microphone/camera permission, or capture flow changed. Simulator and
physical-device validation are required only for later native media surfaces or
capture/permission changes.

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

Phase 2 remains source-backed and proceeds one slice at a time. As of the
Slice 7A mainline closeout, Slices 1 through 4, Slice 5A, Slice 6A, Slice 6B,
Slice 6C, Slice 6D, Slice 6E, and Slice 7A are represented on the consolidated
mainline after independent acceptance. Slice 7A restores durable backend
goal/question lifecycle contracts and bounded queue/resource evidence through
`capability::execute`; autonomous execution, full planning, question UI,
web/research/fetch/browser capability, production deploy, and native
SourceChanges remain deferred. The next discovery slice is Slice 8 unless the
fresh canonical docs identify a narrower required follow-up first.

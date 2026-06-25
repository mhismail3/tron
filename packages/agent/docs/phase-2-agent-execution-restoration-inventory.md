# Phase 2 Agent Execution Restoration Inventory

Status: `complete`

Machine-readable inventory:
[`phase-2-agent-execution-restoration-inventory.tsv`](phase-2-agent-execution-restoration-inventory.tsv)

This inventory is the durable Phase 2 planning map for restored agent
execution. It is grouped by feature family rather than by old file because
future work must restore modern module contracts, not copy the old modular
capability tree.

## Controlled Vocabulary

Classifications:

- `true_primitive`: engine substrate or contract that is small enough to remain
  core.
- `modular_capability_package`: worker-owned package or module outside the
  engine primitive set.
- `ios_surface_only`: device-local iOS workflow state with no backend truth
  claim.
- `server_fact_rendering_only`: iOS or docs render current server-owned facts
  without owning policy.
- `deferred`: valid concept that waits for earlier slices or user decision.
- `reject_candidate`: old behavior is recorded as evidence but should not be
  restored in that form.

Statuses:

- `planned`: accepted in this Phase 2 roadmap, no feature implementation.
- `current_baseline`: already present as primitive substrate or Phase 1 local
  affordance.
- `pending_review`: implementation candidate exists on a branch but is not yet
  independently accepted or integrated into the current mainline baseline.
- `rejected_for_phase2_shape`: old shape rejected, future concept may return
  through another row.

Backend dependency values:

- `none`: current local/iOS/docs surface only.
- `engine_substrate`: requires engine primitive/resource/event/grant work.
- `module_contract`: requires a new worker-owned function/trigger/resource
  contract.
- `ios_native_after_contract`: requires backend module first, then native iOS.
- `physical_device`: requires APNs, microphone, camera, background, or device
  validation.

Memory involvement values:

- `none`: no memory record or retrieval behavior.
- `audit_only`: uses trace/log/resource provenance but no retained memory.
- `reads_memory`: consumes memory records in context or UI.
- `writes_memory`: creates or edits memory records.
- `memory_core`: owns memory primitives, policy, evals, or engine swapping.

## Inventory Summary

The TSV carries every Phase 2 reminder from the Phase 1 progress ledger:
capability discovery, filesystem tools, jobs/processes, worker self-extension,
subagents, goals/queues/questions, approvals, web, git/worktrees,
skills/rules/hooks, memory, MCP, scheduling, program execution,
database/events/settings, dependency restoration, and APNs/device notification
capability.

Slice 6A is the current git/worktree source-control foundation for repository
status and bounded staged/unstaged diff evidence through `domains/git` and
`capability::execute` operation values. Accepted Slice 6B adds index-only
stage/unstage through explicit `git_stage`/`git_unstage` operations over
trusted-root relative paths, with idempotency, mutation reason, expected HEAD
preconditions, bounded before/after evidence, `git_index_change` resources, and
`git.lifecycle` stream events.
Accepted Slice 6C adds Git Commit Evidence Foundation behavior: one commit from
the already-staged index on the current named branch, guarded by expected HEAD,
expected index tree, idempotency, reason, resource evidence, lifecycle events,
and hook/editor/signing suppression. Mainline acceptance followed independent
review and two focused guard fixes.
Accepted Slice 6D adds local branch start: a
provider-visible `git_branch_start` operation through `capability::execute`
that creates one new local branch at `expectedHead`, moves symbolic `HEAD`
without checkout after a locked old-ref/OID guard, preserves index/worktree
content, and records `git_branch_start` resource plus `git.branch_started`
lifecycle evidence. Mainline acceptance followed independent review and two
focused guard fixes.
Worktree graph resources, arbitrary checkout, branch deletion/rename,
merges/rebases/resets, stash/clean, fetch/pull/push, PR handoff, conflict
resolution workflows, and native SourceChanges remain deferred.

Accepted Slice 12 adds the scheduler backend foundation for BPRC-FEATURE-17:
`domains/scheduler`, built-in `schedule` and `schedule_run` resources,
`scheduler.lifecycle` stream evidence, and execute-only `schedule_create`,
`schedule_list`, `schedule_inspect`, `schedule_cancel`, and
`schedule_fire_due` operations. The scheduler owns UTC-instant trigger
evaluation, explicit provider-visible `evaluationAt`, timezone policy labels,
missed-run policy, cancellation, run retention, leases, trace/replay refs, and
bounded projections; feature domains still own what scheduled work does, and
hidden cron loops, APNs/device notification delivery, public scheduler APIs,
native fixed schedule UI, and result merge remain deferred.

It also maps every BPRC backlog row:

- `BPRC-FEATURE-01`: capability discovery, routing, and intent execution.
- `BPRC-FEATURE-02`: filesystem capability suite.
- `BPRC-FEATURE-03`: process, jobs, and sandbox execution.
- `BPRC-FEATURE-04`: web, browser, and research fetching.
- `BPRC-FEATURE-05`: worktree, git, and source-control workflow.
- `BPRC-FEATURE-06`: worker launch, sandbox workers, and self-extension.
- `BPRC-FEATURE-07`: subagents and parallel work orchestration.
- `BPRC-FEATURE-08`: agent queue, goals, work snapshots, and user questions.
- `BPRC-FEATURE-09`: approval and freshness workflows.
- `BPRC-FEATURE-10`: context, compaction, rules, hooks, skills, and memory.
- `BPRC-FEATURE-11`: prompt artifacts.
- `BPRC-FEATURE-12`: notifications, APNs, and device broker.
- `BPRC-FEATURE-13`: audio capture, transcription, and media.
- `BPRC-FEATURE-14`: MCP and external tool sources.
- `BPRC-FEATURE-15`: program execution.
- `BPRC-FEATURE-16`: import, repository, tree, and history tooling.
- `BPRC-FEATURE-17`: cron, background automation, and scheduling.
- `BPRC-FEATURE-18`: system update and diagnostics product surface.
- `BPRC-FEATURE-19`: fixed iOS product panels.
- `BPRC-FEATURE-20`: iOS client, DTO, event, and persistence breadth.
- `BPRC-FEATURE-21`: event protocol surface.
- `BPRC-FEATURE-22`: database and storage tables.
- `BPRC-FEATURE-23`: settings and profile controls.
- `BPRC-FEATURE-24`: dependencies that indicate removed behavior.

## Architecture Notes

The engine should stay a small host fabric. A feature is a true primitive only
when it is required for safe composition of all packages: authority grants,
invocation, resources, streams, queues, triggers, leases, compensation, event
storage, replay, and the worker protocol. Product behavior is modular even
when it is important.

Memory is the main exception in scope, not in implementation. Memory deserves
engine-owned contracts because privacy, provenance, prompt inclusion, deletion,
and migration must survive engine swaps. The memory engine itself remains a
package: deterministic resource memory, vector memory, episodic trace memory,
procedural memory, or future engines can be enabled, disabled, compared, and
migrated without changing the prompt loop contract.

Slice 3 implements only the foundation layer of that architecture: resource
definitions, policy/mode state, redacted record custody, prompt-trace audit
text, eval-run custody, and migration envelopes. It deliberately leaves
semantic/vector retrieval, episodic event retrieval, procedural rules/hooks, and
automatic retention as future packages behind the memory contract.

iOS remains a thin client. The default Phase 2 iOS answer is generic runtime
surface or server-fact rendering. Native surfaces are justified only when the
workflow is stable, frequent, and platform-specific: approvals, questions,
notification inbox, memory audit, source-control review, or file/patch review.

## Handoff Use

Future threads should filter the TSV by `recommended_slice`, then present the
handoff packet required by the scorecard before implementation. A row marked
`planned` does not approve code by itself; it only records that the family is
in scope for Phase 2 and identifies the required owner, validation, and user
decision.

Slice 1 is now represented as current baseline evidence in the TSV where
implemented: catalog discovery search/inspect/report contracts, Runtime
Cockpit discovery rendering, and resource-backed conformance evidence are
recorded on rows `P2AER-INV-002`, `P2AER-INV-025`, and `P2AER-INV-035`.
Rows with remaining provider-reasoning or future-native-surface questions stay
planned until their own contract work lands.

Slice 2 is represented as current backend evidence on rows `P2AER-INV-011`
and `P2AER-INV-034`: approval requests, approval decisions, lifecycle stream
events, idempotent decision recording, reusable fail-closed checks, and
replay/evidence explanations now exist as a modular approval package. A
post-slice hardening guard prevents approval resource kind/schema ids, output
contracts, and persisted payload required fields from drifting against the
engine resource-kernel definitions. The slice intentionally leaves native iOS
approval UI, risk-class taxonomy, default expiry policy, interruption behavior,
and per-package risky-action triggers to future user decisions.

Slice 3 is represented as current backend evidence on rows `P2AER-INV-014`
and `P2AER-INV-019`: the memory domain now owns disabled/active/shadow/compare
policy state, memory engine/policy/record/prompt-trace/eval-run/migration
resource definitions, redacted record lifecycle operations, migration
import/export, and prompt-trace audit without injecting retained memory body
content into provider context. Semantic/vector retrieval, episodic trace
retrieval, procedural rules/hooks/skills, automatic retention, and native iOS
memory UI remain future package or UX decisions behind that foundation.

Slice 4 is represented as current backend evidence on row `P2AER-INV-004`:
the filesystem domain now owns bounded agent read/list/find/glob/search/diff
and write/edit/apply-patch operations through `capability::execute`, with
trusted working-directory roots, traversal and symlink escape denial, bounded
text previews, binary content omission, patch proposal resources,
materialized-file resources for commits, lifecycle stream evidence, and
provider-boundary idempotency for mutating operations. Follow-up orchestrator
review hardened existing-file commits and exact-text edits so unverifiable
truncated snapshots cannot be overwritten or patched from partial preview
content. Native file/patch review UI and package-wide risky-action approval
triggers remain future user decisions.

`P2AER-INV-005` is now implemented as `Slice 5A`: durable jobs and process
lifecycle foundation. The shipped backend adds a `jobs` domain, `job_process`
resources, bounded `execution_output` artifacts, lifecycle stream evidence,
start/status/list/log/cancel provider operations through the existing
`capability::execute` primitive, direct scoped cleanup, fail-closed
`networkPolicy: none`, owned process-group timeout/cancel/shutdown cleanup,
cancel-request-before-terminal finalization with stale-version retry, retention
archiving, and focused resource/authority/bounded-output tests. `P2AER-INV-006` stays
planned for a later program-execution slice; Slice 5A did not restore language
runtimes, PTY sessions, web/network research, git/source-control, subagents,
scheduling, notifications, or native iOS process panels. Queue-backed internal
job dispatch also remains deferred pending an explicit queued-grant design.

`P2AER-INV-013` is current baseline for Slice 6A read-only Git status/diff
evidence, accepted Slice 6B index-only stage/unstage, accepted Slice 6C
staged-index commit evidence, and accepted Slice 6D local `git_branch_start`
branch creation with locked symbolic-HEAD movement. The
mutating boundary is intentionally narrow: explicit paths for index mutation,
resource-backed evidence, lifecycle stream evidence, expected HEAD freshness,
expected index-tree freshness for commit, idempotency, branch-name validation,
and static guards proving no arbitrary checkout, branch delete/rename,
merge/rebase/reset, push/PR, worktree graph, conflict resolution workflow, or
native SourceChanges surface was added. Accepted Slice 6E adds read-only local
branch inventory through the existing `capability::execute` and `domains/git`
boundary: `git_branch_inventory` enumerates sorted local `refs/heads/*`,
reports current or detached HEAD evidence, includes branch OIDs, optional local
upstream/ahead-behind evidence, bounded last-commit metadata with oversized
metadata rows retained as truncated evidence, and branch count/byte truncation
metadata without adding a durable resource kind. Branch deletion/rename, arbitrary
checkout, remote push/PR, merge/rebase/reset, conflict workflows, worktree graph
resources, and native SourceChanges remain deferred.

`P2AER-INV-010` is current baseline after accepted Slice 7A:
Goal And Question Foundation. Slice 7A adds a backend `domains/goals`
owner for durable goal lifecycle records, user-question records, idempotent
answer provenance, lifecycle stream evidence, queue/resource refs, trace refs,
and replay refs behind the existing `capability::execute` primitive. It reuses
existing resource/stream/replay/idempotency substrate, narrows the generic
`goal` resource schema for lifecycle/evidence refs, and adds only
`user_question` and `goal_answer` resource kinds. Autonomous goal execution,
hidden prompt queues, planner/task decomposition, scheduler/reminder behavior,
notifications/APNs, subagents, native iOS Work dashboards, native question
sheets, public `/engine` goal APIs, and copied historical DTOs remain deferred.
The accepted review/fix loop added explicit `capability::execute` scope,
resource-kind, and selector checks for goal/question operations before handler
execution.

`P2AER-INV-012` is current baseline after accepted Slice 8E:
Web Robots Policy Foundation.
Slice 8A adds
`domains/web` as the package owner, one execute-only `web_fetch` operation,
declared-network authority checks, bounded direct fetch, sanitized URL/final
URL evidence, content-type handling, deterministic byte/output truncation
metadata, captured-byte SHA-256 evidence, common secret redaction, trace refs,
replay refs, idempotent `web_source` resource/cache evidence, and
`web.lifecycle` stream evidence. Search providers, browser automation, crawling,
robots policy, login/cookies/session reuse, credential handling, public
`/engine` web APIs, native iOS source UI, and network-enabled jobs remain
deferred to later Slice 8 sub-slices.

Slice 8B adds execute-only read operations
`web_source_list` and `web_source_inspect` under the same `domains/web`
boundary. They require trusted current-session context plus `web.read` and
`resource.read` authority, inspect only scoped `web_source` resources, reject
malformed ids, wrong kinds, missing/stale versions, cross-session sources, and
missing read authority, and return bounded citation-ready URL/status/content
type/hash/truncation/redaction/snippet/trace/replay/resource refs without
network I/O.

Slice 8C accepts Web HTML/Text Extraction And Citation Quality Foundation. It
keeps `web_fetch`, `web_source_list`, and `web_source_inspect` as the only
provider-visible web operations, adds deterministic HTML/XHTML readable-text
extraction before output bounding and redaction, records bounded/redacted
extraction mode/extractor/title/extracted-byte/truncation metadata under
`textEvidence`, preserves raw captured-byte SHA-256 provenance, and keeps source
list/inspect read-only and backward-compatible with older `web_source` records.

Slice 8D accepts Web Source Retention And Cache Policy Foundation. It adds
execute-only `web_source_archive`, archives only current-session `web_source`
resources through append-only CAS lifecycle updates, preserves source evidence
and replay/citation refs, defaults `web_source_list` to active/fetched records,
exposes archived records only with explicit `includeArchived`, keeps exact
archived inspect available, and keeps archive/list/inspect under
`networkPolicy: none`. Search providers, browser automation, crawling, robots
policy, login/cookies/session reuse, deletion/pruning/automatic TTL cleanup,
public `/engine` web APIs, native iOS source UI, and network-enabled jobs remain
deferred.

Slice 8E accepts Web Robots Policy Foundation. It adds execute-only
`web_robots_check`, fetches one origin `robots.txt` under declared network
authority after trusted current-session/idempotency, `web.write`,
`resource.read`, `resource.write`, `kind:web_robots_policy`, and existing
URL/redirect/DNS safety checks, records `web_robots_policy` evidence with
bounded body/hash/parser/decision/sitemap metadata, requires HTTPS in production
with only explicit test-only HTTP loopback fixtures, and keeps sitemap
traversal, search providers, browser automation, crawling beyond the single
robots fetch, login/cookies/session reuse, public `/engine` web APIs, native iOS
source UI, deletion/pruning/TTL cleanup, and network-enabled jobs deferred.

Slice 8F accepts Web Fetch Robots Evidence Linkage Foundation. It keeps
`web_fetch` compatible by default, adds optional paired robots evidence inputs
`webRobotsPolicyResourceId` and `expectedWebRobotsPolicyVersionId`, validates a
current-session `web_robots_policy` allow decision for the exact requested
origin/target before target fetch HTTP client construction, uses a
non-displayed canonical target fingerprint so sanitized sensitive URL values do
not authorize other targets, records only bounded `robotsPolicyRefs` on
resulting `web_source` payloads, exposes those bounded refs through source
list/inspect, and conditionally derives the additional robots-policy read grants
only when both robots fields are non-empty strings. Search, browser, crawl,
sitemap traversal, login/cookies, public `/engine`, native iOS, settings,
migrations, cleanup/TTL, and network-job scope remain deferred.

`P2AER-INV-008` is current baseline after accepted Slice 9A: External Tool
Source Proposal And Provenance Foundation. It adds an inert `tool_sources`
domain plus `tool_source_proposal` and `tool_source_conformance_report`
resource kinds so external source identity,
provenance, sandbox intent, declared tool/schema metadata, expected
worker/package linkage, trace/replay refs, lifecycle state, and bounded
preflight evidence can be inspected before any activation. Proposal/report
writes are internal-only and require trusted system/admin authority, derived
non-bootstrap grants, explicit non-wildcard resource authority for the resource
kind being written, idempotency, and `networkPolicy: none`. Agent access is
read-only through `tool_source_list` and `tool_source_inspect` under the
existing `capability::execute` primitive with explicit resource-kind authority
and matching kind selectors for the inspected resource kind.
Slice 9A explicitly does not start MCP servers, install packages, register
catalog tools, execute proposed tools, promote trust, change worker lifecycle,
add browser/search/crawl/login scope, expand public `/engine`, or add fixed
iOS UI.

`P2AER-INV-007` is current baseline after accepted Slice 9B: Worker Package
Lifecycle Inspection Foundation. It adds read-only `worker_package_list` and
`worker_package_inspect` operation values behind the existing
`capability::execute` primitive so model-visible execution can inspect bounded
worker lifecycle evidence already stored in trusted resources. The accepted path
requires trusted current-session context, `worker.lifecycle.read`,
`resource.read`, explicit non-wildcard resource-kind grants, matching
`kind:worker_*` selectors, and `networkPolicy: none`; it revalidates stored
kind/schema and redacts raw manifests, scoped tokens, env values, endpoints,
token grant details, direct authority-grant ids, grant-like nested metadata,
and local paths. It does not propose, install, enable, disable, launch, stop,
retire, register, execute, promote trust, expand public `/engine`, or add
native fixed package UI.

`P2AER-INV-009` is current baseline after accepted Slice 10B:
Subagent Worker Launch Foundation. Accepted Slice 10A adds inert `subagents`
domain coverage and one `subagent_task` resource kind for lifecycle/provenance
records. Accepted Slice 10B keeps `subagent_task` as the parent causality anchor
and adds provider-visible `subagent_launch`, `subagent_status`,
`subagent_result`, and `subagent_cancel` lifecycle operations under the existing
`capability::execute` primitive. Launch requires trusted current-session context,
`subagents.read`/`subagents.write` plus `resource.read`/`resource.write`
authority, exact `kind:subagent_task` selectors, idempotency, explicit
`modelPolicy: bounded_placeholder_v1`, bounded objective/prompt summaries,
one-running-task-per-scope concurrency, parent session/workspace/trace refs,
replay refs, and no-network policy. Status/result return allowlisted
bounded/redacted projections; cancel records idempotent cancellation provenance
with optional expected-version freshness. Actual child-agent process execution,
worker/package launch, job/process start, tool execution, scheduling, result
merge into conversation state, public `/engine` expansion, settings/profile
migrations, actual spawn/status/result/cancel workers and iOS chips/sheets, and
native fixed iOS subagent UI remain deferred to later Slice 10 work.

`P2AER-INV-017` is current baseline after accepted Slice 11A: Procedural State
Provenance And Inspection Foundation. The accepted slice adds inert
`procedural_record` resources for skill/rule/hook/procedure provenance, eval,
status, refs, and activation-proof metadata plus read-only
`procedural_state_list` and `procedural_state_inspect` operation values behind
the existing `capability::execute` primitive. The slice requires trusted
current-session/workspace context, `procedural.read`, `resource.read`, explicit
non-wildcard `procedural_record` resource-kind authority, exact
`kind:procedural_record` and `proceduralKind:*` selectors, stored
kind/schema/version/status revalidation, scope isolation, bounded/truncated
output, and redaction of secrets, env values, grant ids, unsafe paths, raw
manifests/logs, and private nested metadata. It does not restore repo-managed
skills, skill-copy/bootstrap prompt wiring, activation, trigger firing, learned
behavior, autonomous execution, scheduler work, tool execution, worker/package/
job/process/network launch, MCP lifecycle, package install/catalog
registration, trust promotion, public `/engine` expansion, settings/profile
migrations, browser/search/crawl/login scope, native fixed UI, or result merge
into conversation state.

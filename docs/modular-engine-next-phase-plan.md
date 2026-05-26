# Subagent Lineage Generated Surfaces And Capability-Backed Result Truth Plan

## Current Checkpoint

The repo-wide production-grade rubric remains complete at `100/100`. The
stricter capability-backed-truth score is now `96/100`:

- memory retain durable truth is `artifact` plus `materialized_file` substrate
  truth;
- notification delivery/read truth is `notification`, `evidence`, and
  `decision` substrate truth;
- Prompt Library and Voice Notes durable outputs are resource-backed;
- model-facing capability use is routed through the single `execute`
  orchestrator.

The next highest-value blocker is subagent/result lineage. Fixed Swift sheets
and event plugins still interpret child-agent pending/result state. The engine
already has invocation, resource, stream, and event truth; the next phase should
make that truth server-authored, generated, inspectable, and stale-safe before
any fixed shell is removed.

## First-Principles Goal

Subagents are child execution. The durable truth should answer:

- what parent invocation requested the child work;
- what child invocation, worker, model, prompt, grants, approvals, and resource
  outputs were used;
- whether the child is pending, running, completed, failed, cancelled, retried,
  or stale;
- what result resources were produced and whether they are current, damaged, or
  discarded;
- what safe next action exists for the operator or parent agent;
- why a stale event, missing result, cancelled run, or failed retry is not
  actionable.

The source of truth should be invocations, grants, decisions, evidence,
resources, streams, queues, and generated UI resources. Fixed client event
plugins may render thin chat affordances, but they must not own lineage,
result truth, retry policy, or action payloads.

## Scope

Build the next checkpoint as:

1. a complete subagent lineage inventory over current `agent::*` capabilities,
   invocation records, events, resources, streams, and fixed Swift surfaces;
2. server-authored generated list/detail surfaces for subagent pending,
   completed, failed, cancelled, and retried states;
3. resource/evidence refs for result payloads that are currently only
   event/plugin interpreted;
4. static gates that prevent fixed sheets from owning result truth or action
   payload construction;
5. docs and score updates from `96/100` only after tests prove the boundary.

Keep existing public capability ids and response fields stable unless a
separate clean-break plan explicitly authorizes a schema change.

## Non-Goals

- No new subagent/product tables.
- No compatibility reader or fallback event-result interpreter.
- No client-owned grants, retry policy, generated action target construction,
  payload templates, or result lineage.
- No dynamic UI catalog or `control::act`.
- No deletion of fixed chat chips/sheets until generated surfaces preserve the
  current operator role and have absence/source guards.

## Implementation Plan

### 1. Inventory And Characterization

- Map `agent::spawn_subagent`, `agent::subagent_status`,
  `agent::subagent_result`, and related runner events to their current durable
  records.
- Identify every fixed Swift surface/plugin that consumes subagent pending or
  result state.
- Add characterization tests that prove current child invocations, failures,
  cancellations, retries, and result references can be reconstructed from
  substrate truth.

### 2. Result Truth Hardening

- Ensure child-agent outputs that affect future prompts or operator decisions
  are `agent_result`, `artifact`, `evidence`, or existing resource-backed
  outputs with top-level `resourceRefs`.
- Failure or cancellation should produce bounded evidence, not hidden client
  state.
- Duplicate child execution/retry idempotency must not duplicate result
  resources, child invocations, or approvals.

### 3. Generated Lineage Surfaces

- Extend `ui::surface_for_target` only if existing target types cannot express
  child invocation/resource lineage cleanly.
- Prefer existing target types: `invocation`, `resource`, `goal`, and
  constrained `resource_collection`.
- Generated subagent list/detail surfaces should show:
  - parent/child invocation refs;
  - status and latest evidence;
  - model/worker/grant refs;
  - result resource refs and bounded previews;
  - failure/cancellation/retry diagnostics;
  - canonical actions only when target revisions, grants, and schemas are
    current.

### 4. iOS Thin-Shell Boundary

- Keep chat chips as local navigation affordances if they only open
  server-authored lineage surfaces.
- Remove fixed result/detail interpretation only after generated surfaces cover
  pending, completed, failed, cancelled, and retried UX.
- Add source guards forbidding fixed subagent surfaces from constructing target
  functions, payload templates, grants, result lineage, or retry policy.

### 5. Docs, Score, And Ledger

- Update `docs/capability-backed-truth-migration-plan.md`.
- Update `docs/product-shell-reachability-map.md`.
- Update `docs/modular-engine-cleanup-audit.md`.
- Update `docs/production-grade-rubric.md`.
- Update README only if public capability behavior or schema lists change.
- Update `~/LEDGER.jsonl` after verification.

## Test Plan

- Focused Rust tests:
  - child invocation lineage survives resume/restart;
  - pending/completed/failed/cancelled/retried states are reconstructable from
    substrate truth;
  - result resources/evidence refs are returned and inspectable;
  - duplicate retries do not duplicate child invocations or result resources;
  - generated lineage surfaces expose refs, bounded previews, and canonical
    actions only.
- Generated UI tests:
  - stale target revisions fail before action execution;
  - unsupported subagent states render as inspectable warnings, not fabricated
    success;
  - generated surfaces do not inline unbounded result payloads or raw secrets.
- Static gates:
  - no subagent/result product tables;
  - no fixed Swift result-lineage policy or generated-action construction;
  - no `control::act`, dynamic UI catalog, compatibility alias, fallback
    reader, raw-scope authorization, or module action multiplexer.
- Verification:
  - `cd packages/agent && cargo test agent:: --lib -- --nocapture`;
  - focused generated UI tests;
  - `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`;
  - `cd packages/agent && RUSTFLAGS="-D warnings" cargo check --all-targets`;
  - `git diff --check`;
  - `scripts/tron ci fmt check clippy test`;
  - iOS `xcodegen generate` and targeted source-guard/subagent tests only if
    Swift files change.

## Acceptance Criteria

- Subagent/result truth is reconstructable without hidden client event state.
- Generated lineage surfaces cover all important child execution states.
- Fixed Swift surfaces either become thin navigation shells or are removed with
  absence gates.
- Every mutation still runs through canonical capabilities and stored generated
  actions.
- The capability-backed-truth score only increases when tests, docs, static
  gates, and full verification pass.

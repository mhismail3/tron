# Source-Control And AgentControl Generated Surfaces Plan

## Current Checkpoint

The repo-wide production-grade rubric remains complete at `100/100`. The
stricter capability-backed-truth score is now `97/100`:

- memory retain durable truth is `artifact` plus `materialized_file` substrate
  truth;
- notification delivery/read truth is `notification`, `evidence`, and
  `decision` substrate truth;
- completed subagent result truth is deterministic `agent_result:subagent:*`
  resource truth, with generated `subagent.lineage.v1` surfaces;
- Prompt Library and Voice Notes durable outputs are resource-backed;
- model-facing capability use is routed through the single `execute`
  orchestrator.

The next highest-value blocker is source-control and AgentControl review
surfaces. They remain fixed Swift shells because they combine chat context,
model/settings visibility, worktree status, diff review, conflict handling, and
deferred prompts. The next phase should move the durable/review truth behind
those workflows into server-authored generated surfaces without weakening user
review quality.

## First-Principles Goal

Source-control and AgentControl surfaces are operator review boundaries. The
durable truth should answer:

- what workspace, session, worktree, branch, file set, and diff state is being
  reviewed;
- which capability, invocation, grant, approval, and resource/evidence refs
  support each suggested action;
- whether the displayed source-control state is current, stale, conflicted,
  dirty, blocked, or already applied;
- what action will mutate state, what approval/risk applies, and what exact
  target revision will be checked before execution;
- what is local editing/navigation state versus server-owned substrate truth;
- why a stale, conflicting, unauthorized, or unsupported action is not safe.

The source of truth should be invocations, grants, resources, decisions,
evidence, worktree/git capability results, generated UI resources, and stored
canonical actions. Fixed Swift surfaces may remain as local navigation or
composition affordances, but they must not own review truth, mutation payloads,
grant construction, stale-state decisions, or action policy.

## Scope

Build the next checkpoint as:

1. a complete AgentControl/source-control inventory over current Swift sheets,
   Rust capabilities, worktree/git outputs, events, and generated UI support;
2. generated review surfaces for worktree status, changed-file summaries, diff
   previews, conflict state, deferred prompts, and canonical git/worktree
   actions;
3. server-owned action consequence summaries for source-control and
   AgentControl actions;
4. static gates that fixed Swift shells cannot construct target functions,
   payload templates, grants, revision decisions, source-control policy, or
   stale-state approvals;
5. docs and score updates from `97/100` only after tests prove the boundary.

Keep existing public capability ids and response fields stable unless a
separate clean-break plan explicitly authorizes a schema change.

## Non-Goals

- No new source-control/product tables.
- No compatibility reader, fallback route, or fallback renderer.
- No client-owned grants, target functions, generated action payloads,
  stale-state policy, retry policy, or source-control mutation decisions.
- No dynamic UI catalog or `control::act`.
- No deletion of fixed chat/source-control shells until generated surfaces
  preserve the current operator role and have absence/source guards.
- No broad source-control UX redesign unrelated to server-owned truth.

## Implementation Plan

### 1. Inventory And Characterization

- Map AgentControl and SourceChanges entrypoints, DTOs, state objects, actions,
  and current tests.
- Map `git::*`, `worktree::*`, source-control workflow helpers, deferred prompt
  paths, and any invocation/resource/evidence refs they currently expose.
- Identify which current display fields are durable truth, projection state,
  local editing state, or ephemeral UI affordances.
- Add characterization tests for current source-control action prerequisites,
  stale worktree behavior, conflict state, deferred prompt submission, and
  generated action submission constraints.

### 2. Server-Owned Review Projections

- Add or reuse generated `ui::surface_for_target` profiles that can represent:
  - worktree summary and cleanliness;
  - changed-file list with bounded diff previews;
  - conflict state and conflict-resolution prerequisites;
  - pending/deferred source-change prompts;
  - canonical actions such as refresh, inspect diff, stage/unstage where
    supported, apply patch, commit, rollback/discard where safe, and submit
    deferred prompt.
- Each action must be stored on a `ui_surface`, revision-pinned,
  idempotency-aware, approval-aware, and routed through `ui::submit_action`.
- Large diffs, secret-like content, local file paths, and raw payload templates
  must be bounded or omitted with inspectable refs.

### 3. AgentControl Generated Surfaces

- Author generated surfaces for server-owned context that AgentControl currently
  displays: active model/settings summary, capability health/search entrypoints,
  selected workspace/session refs, skill visibility, source-control entry
  points, and safe next actions.
- Keep local shell behavior only where it is genuine navigation/composition,
  such as opening a chat sheet or choosing where a generated surface appears.
- Use existing action-summary/consequence helpers so action state, required
  approval, target revision, and stale/block reasons match control projections.

### 4. iOS Thin-Shell Boundary

- Keep `AgentControlView` and SourceChanges sheets as local containers only if
  they render server-authored surfaces or navigate to them.
- Remove fixed mutation controls only after equivalent generated actions are
  available and tested.
- Add source guards forbidding fixed shells from constructing target functions,
  payload templates, grants, source-control mutation policy, stale-state
  decisions, or generated UI action submissions outside stored coordinates.

### 5. Docs, Score, And Ledger

- Update `docs/capability-backed-truth-migration-plan.md`.
- Update `docs/product-shell-reachability-map.md`.
- Update `docs/modular-engine-cleanup-audit.md`.
- Update `docs/production-grade-rubric.md`.
- Update README only if public capability behavior or schema lists change.
- Update `~/LEDGER.jsonl` after verification.

## Test Plan

- Focused Rust tests:
  - generated source-control surfaces expose bounded worktree/diff/conflict
    refs and no raw unbounded payloads;
  - stale worktree revisions fail before mutation;
  - deferred source-change prompts submit through stored canonical actions;
  - mutating git/worktree actions keep existing approval/output-contract
    behavior;
  - generated AgentControl surfaces expose refs and action summaries without
    durable control state.
- Generated UI tests:
  - stored source-control actions are schema-valid, revision-pinned,
    idempotent when mutating, approval-aware, and stale-safe;
  - unsupported source states render inspectable warnings, not fabricated
    success;
  - `ui::submit_action` rejects stale/damaged/expired surfaces before child
    execution.
- iOS/source-guard tests:
  - fixed AgentControl/SourceChanges shells do not construct target functions,
    payload templates, grants, source-control mutation policy, or stale-state
    approvals;
  - if a fixed mutation control is removed, its navigation/action references,
    previews, and tests are removed with absence gates.
- Static gates:
  - no source-control/product tables;
  - no `control::act`, dynamic UI catalog, compatibility alias, fallback reader,
    raw-scope authorization, module action multiplexer, or alternate worker
    spawn path.
- Verification:
  - `cd packages/agent && cargo test generated_ui --lib -- --nocapture`;
  - focused source-control/worktree tests;
  - `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`;
  - `cd packages/agent && RUSTFLAGS="-D warnings" cargo check --all-targets`;
  - `git diff --check`;
  - `scripts/tron ci fmt check clippy test`;
  - iOS `xcodegen generate` and targeted AgentControl/SourceChanges tests only
    if Swift files change.

## Acceptance Criteria

- Source-control/AgentControl durable review truth is reconstructable from
  server substrate records.
- Generated surfaces cover the highest-risk review and mutation workflows with
  stored canonical actions.
- Fixed Swift surfaces either become thin local containers/navigation shells or
  are removed with absence gates.
- Every mutation still runs through canonical capabilities and stored generated
  actions.
- The capability-backed-truth score only increases when tests, docs, static
  gates, and full verification pass.

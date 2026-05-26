# Final Capability-Backed Truth Audit And Scheduler Cache Decision Plan

## Current Checkpoint

The stricter capability-backed-truth score is now `99/100`.

Completed conversion slices:

- retained memory truth is `artifact` plus `materialized_file` substrate truth;
- notification delivery/read truth is `notification`, `evidence`, and
  `decision` substrate truth;
- completed subagent result truth is deterministic `agent_result` resource
  truth with generated lineage surfaces;
- source-control and AgentControl review now have server-authored generated
  `source_control.session.v1` and `agent_control.session.v1` surfaces with
  stored canonical actions;
- cron schedule definitions are `decision:cron-schedule:*` resources and
  completed run observations are `evidence:cron-run:*` resources;
- model-facing capability use goes through the single `execute` orchestrator.

The only remaining capability-backed-truth blocker is the cron runtime scheduler
cache. `cron_jobs` and `cron_runs` are no longer product truth, but they still
exist as timer/executor/cache tables. The final phase must either remove them
with a clean storage generation reset or formally accept them as low-level
scheduler substrate with static gates proving they cannot own product policy,
operator truth, or agent-facing durable state.

## First-Principles Goal

The final 100/100 state must make this statement true:

Every durable fact that affects agent behavior, operator state, retries,
approvals, future prompts, or user-visible state is reconstructable from
canonical capabilities and collapsed substrate truth. Any remaining table/file is
strictly mechanical substrate and cannot become a hidden source of policy or
product truth.

## Phase Scope

Build the next checkpoint as a final proof phase:

1. Re-audit every capability-backed-truth conversion candidate.
2. Decide whether the cron runtime cache is removable or should remain accepted
   scheduler substrate.
3. If removable, bump storage generation and remove `cron_jobs` / `cron_runs`
   from fresh schema plus runtime code.
4. If accepted, add stronger static gates and docs that confine the cache to
   timer/executor mechanics only.
5. Prove the single model-facing `execute` path can still resolve, prepare, run,
   and observe core capabilities with no hidden search/inspect dependency.
6. Update score/docs/README/ledger only after full verification passes.

## Non-Goals

- No compatibility reader, row-copy migration, fallback DTO, or retired cron file
  reader.
- No `control::act`, dynamic UI catalog, client-authored action target, or
  client-owned policy.
- No marketplace, remote package fetch, package trust expansion, or worker-spawn
  path change.
- No public capability id or schema change unless a blocker proves the old shape
  is unsafe.

## Work Plan

### 1. Final Conversion Inventory

- Re-scan Rust domains, engine primitives, iOS/Mac shells, scripts, schemas, and
  docs for unclassified durable state.
- Confirm memory, notifications, prompt library, voice notes, subagent lineage,
  source-control/AgentControl, and cron all have focused tests and static gates.
- Add absence checks for any retired files/tables/routes discovered during the
  scan.

### 2. Cron Runtime Cache Decision

- Inspect every production read/write of `cron_jobs` and `cron_runs`.
- Classify each access as timer wakeup, running-state cache, retry bookkeeping,
  stuck-run cleanup, delivery bookkeeping, or product/operator truth.
- Remove or rewrite any product/operator read to decision/evidence/invocation
  truth.
- Decide:
  - **Remove** if runtime can derive due work entirely from decisions plus queue
    state without weakening retry/stuck-run behavior.
  - **Accept as substrate** if the tables are strictly mechanical and a removal
    would only reimplement queue/lease mechanics under another name.

### 3. Removal Path If Feasible

- Bump storage generation.
- Remove `cron_jobs`, `cron_runs`, cron indexes, and cron table tests from the
  fresh consolidated schema.
- Replace timer state with queue/lease/resource-derived due work.
- Persist all run outcomes through evidence and canonical invocations.
- Add absence gates proving fresh DBs do not create cron tables.

### 4. Accepted-Substrate Path If Removal Is Safer

- Keep `cron_jobs` / `cron_runs` only as scheduler cache.
- Add static gates proving:
  - cron public list/get/get-runs never read cache as truth;
  - schedule mutations write decisions first;
  - completed run observations attach evidence;
  - production `automations.json` readers remain absent;
  - README/schema docs call cron tables cache, not product truth.
- Add recovery tests showing schedule truth can repopulate an empty runtime
  cache.

### 5. Execute-Orchestrator Final Proof

- Run manual and automated tests for intent-only resolution, explicit target
  hints, read-only execution, sandbox materialized execution, approval pause and
  resume, generated UI action execution, and failure correction diagnostics.
- Ensure all execution details remain inspectable through invocation/audit
  substrate without exposing model-visible `search` / `inspect` tools.

### 6. Docs, Score, And Ledger

- Update `docs/capability-backed-truth-migration-plan.md` to 100/100 only when
  the final cache decision has proof.
- Update `docs/production-grade-rubric.md`,
  `docs/modular-engine-cleanup-audit.md`, `README.md`, and any touched
  progressive docs.
- Append `~/LEDGER.jsonl` with the final decision, score, and verification
  outcome.

## Verification

- Focused Rust tests for cron resources/cache recovery or removal.
- `cd packages/agent && cargo test generated_ui --lib -- --nocapture`.
- `cd packages/agent && cargo test resource_ --lib -- --nocapture`.
- `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`.
- `cd packages/agent && RUSTFLAGS="-D warnings" cargo check --all-targets`.
- `git diff --check`.
- `scripts/tron ci fmt check clippy test`.
- iOS/Mac `xcodegen generate` and targeted tests only if client/project files
  change.

## Acceptance Criteria

- Capability-backed-truth score reaches 100/100 only with proof.
- No unclassified durable state owner remains.
- No hidden file/table state affects agent behavior, operator truth, retries, or
  approvals.
- No client-owned grant, lineage, action-template, or policy path remains.
- Every autonomous workflow runs through canonical invocation/capability paths
  and leaves inspectable substrate evidence.
- All retired tables/files/routes/fallbacks are removed or statically forbidden.

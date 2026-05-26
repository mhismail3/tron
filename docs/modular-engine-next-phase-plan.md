# Post-100 Capability-Backed Truth Hardening Plan

## Current Checkpoint

The stricter capability-backed-truth score is now `100/100`.

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
- `cron_jobs` and `cron_runs` are formally accepted low-level scheduler cache,
  not product truth, with static gates and recovery tests;
- model-facing capability use goes through the single `execute` orchestrator.

The final scheduler-cache decision is complete: removing the runtime cron tables
would reimplement timer wakeup, in-flight run, retry, delivery, and stuck-run
bookkeeping under another name. They remain accepted substrate, while public
cron schedule/run truth is decision/evidence-backed.

## First-Principles Goal

Keep the 100/100 state true as the system evolves:

Every durable fact that affects agent behavior, operator state, retries,
approvals, future prompts, or user-visible state must be reconstructable from
canonical capabilities and collapsed substrate truth. Any remaining table/file
must be strictly mechanical substrate and must not become hidden policy or
product truth.

## Next Work Theme

The next comprehensive phase should not add product features. It should harden
the 100/100 state through continuous proof:

1. Expand adversarial tests around the single `execute` orchestrator.
2. Add periodic whole-repo truth-owner scans to catch new hidden state before it
   ships.
3. Improve generated UI/operator inspection for capability-backed workflows only
   where it reduces manual debugging.
4. Keep iOS/Mac clients thin by verifying every new action is server-authored or
   a genuine local editing/hardware affordance.
5. Preserve cron cache classification and prevent public reads from depending
   on runtime cache rows.

## Non-Goals

- No compatibility reader, row-copy migration, fallback DTO, or retired file
  reader.
- No `control::act`, dynamic UI catalog, client-authored action target, or
  client-owned policy.
- No marketplace, remote package fetch, package trust expansion, or worker-spawn
  path change.
- No public capability id or schema change unless a blocker proves the old shape
  is unsafe.
- No new table or file truth without updating the capability-backed-truth
  tracker first.

## Work Plan

### 1. Continuous Truth-Owner Scan

- Add or maintain scans over Rust domains, engine primitives, iOS/Mac shells,
  scripts, schemas, docs, and generated projects for new durable writes,
  new tables, local caches, client-owned policy, and generated action
  construction.
- Require any new durable owner to be classified as resource/decision/evidence/
  invocation/grant truth or low-level substrate.
- Add absence gates immediately for removed or rejected paths.

### 2. Execute-Orchestrator Stress Matrix

- Keep the single model-facing `execute` primitive as the only provider-visible
  capability gateway.
- Stress intent-only resolution, explicit target hints, ambiguous matches,
  missing required input, constraints, read-only process execution,
  sandbox-materialized process execution, approval pause/resume, generated UI
  action submission, idempotency replay, and correction diagnostics.
- Every failed prepare/run path should produce actionable result details and
  `capability.orchestration` audit evidence without hidden child execution.

### 3. Scheduler Cache Guardrail Maintenance

- Keep `cron_jobs` and `cron_runs` scoped to due-time, in-flight execution,
  retry, delivery, and stuck-run mechanics.
- Public cron list/get/get-runs/run paths must bind from decisions/evidence and
  reject cache-only rows.
- Runtime cache may be repopulated from schedule decisions, but schedule
  decisions must never be inferred from cache-only rows.

### 4. Client Thinness Regression Suite

- Verify iOS/Mac product shells continue to submit stored generated UI action
  coordinates or local editing/hardware events only.
- Keep Prompt Library picker, chat composer, voice recording, and display stream
  classified as local affordances only where there is no durable engine truth
  before submission.
- Add source guards before removing or replacing any remaining fixed shell.

### 5. Operator Inspection And Recovery

- Prefer server-owned projections over fixed client interpretation.
- Add generated inspection surfaces only when they expose existing substrate
  truth more clearly; do not create new status caches.
- Ensure every autonomous workflow has inspectable invocation/evidence/resource
  lineage and a safe recovery or retry path.

### 6. Docs, Score, And Ledger

- Keep `docs/capability-backed-truth-migration-plan.md`,
  `docs/production-grade-rubric.md`, `docs/modular-engine-cleanup-audit.md`,
  README, and progressive module docs synchronized.
- The score may remain 100/100 only while all static gates and verification
  checks pass.
- Append `~/LEDGER.jsonl` for every meaningful cleanup or durable decision.

## Verification

- Focused Rust tests for touched domains.
- `cd packages/agent && cargo test generated_ui --lib -- --nocapture` when
  generated surfaces change.
- `cd packages/agent && cargo test resource_ --lib -- --nocapture` when
  resource contracts change.
- `cd packages/agent && cargo test --test threat_model_invariants -- --nocapture`.
- `cd packages/agent && RUSTFLAGS="-D warnings" cargo check --all-targets`.
- `git diff --check`.
- `scripts/tron ci fmt check clippy test` before checkpoint commits.
- iOS/Mac `xcodegen generate` and targeted tests only if client/project files
  change.

## Acceptance Criteria

- Capability-backed-truth score remains 100/100 with proof.
- No unclassified durable state owner appears.
- No hidden file/table state affects agent behavior, operator truth, retries, or
  approvals.
- No client-owned grant, lineage, action-template, or policy path appears.
- Every autonomous workflow runs through canonical invocation/capability paths
  and leaves inspectable substrate evidence.
- All retired tables/files/routes/fallbacks are removed or statically forbidden.

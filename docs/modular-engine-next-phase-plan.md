# Cron And Scheduled Work Capability-Backed Truth Plan

## Current Checkpoint

The stricter capability-backed-truth score is now `98/100`.

Completed conversion slices:

- retained memory truth is `artifact` plus `materialized_file` substrate truth;
- notification delivery/read truth is `notification`, `evidence`, and
  `decision` substrate truth;
- completed subagent result truth is deterministic `agent_result` resource
  truth with generated lineage surfaces;
- source-control and AgentControl review now have server-authored generated
  `source_control.session.v1` and `agent_control.session.v1` surfaces with
  stored canonical actions;
- model-facing capability use goes through the single `execute` orchestrator.

The remaining capability-backed-truth blocker is cron/scheduled work. Cron still
has a dedicated scheduler product plane with separate schedule/run truth. The
next phase should either convert that truth to resources/decisions/invocations/
evidence or prove that cron is acceptable low-level scheduler substrate with
narrow static gates. The default decision is conversion.

## First-Principles Goal

Scheduled work changes future agent behavior. The durable truth must answer:

- who created or updated the schedule;
- what canonical capability/action will run;
- what scope, grant ceiling, approval policy, and idempotency key apply;
- what cadence, timezone, expiry, and missed-window behavior apply;
- which queue item, invocation, result, evidence, and resource refs belong to
  each run;
- whether a schedule is active, expired, revoked, stale, malformed, or blocked;
- how an operator inspects, disables, retries, or deletes the schedule without
  touching hidden files/tables.

The source of truth should be existing `decision`, `evidence`, invocation,
grant, queue, lease, and generated UI resources. Queue and lease internals may
remain substrate mechanics; product schedule/run truth should not live in a
parallel cron table or JSON file.

## Scope

Build the next checkpoint as:

1. a complete inventory of current `cron::*` capabilities, scheduler files,
   database tables, iOS DTO/client paths, tests, and docs;
2. a conversion design for schedules as resource/decision truth and runs as
   invocation/evidence truth;
3. implementation of the smallest coherent conversion slice that removes hidden
   scheduler product truth without weakening retries or operator control;
4. generated schedule list/detail surfaces with stored canonical actions;
5. static gates forbidding retired cron tables/files/readers if conversion is
   completed, or documenting an accepted-substrate decision if not;
6. docs and score updates from `98/100` only after full verification passes.

## Non-Goals

- No compatibility reader or row-copy migration.
- No new scheduler table.
- No client-owned target function, payload template, grant, retry policy,
  cadence policy, or stale-state decision.
- No dynamic UI catalog or `control::act`.
- No marketplace, remote package fetch, or worker-spawn changes.
- No broad iOS scheduler redesign until server truth is proven.

## Implementation Plan

### 1. Inventory And Characterization

- Map current cron state owners: files, tables, DTOs, queue paths, run records,
  routes, and tests.
- Identify which state is durable product truth versus queue/lease substrate.
- Add characterization tests for create/update/delete/list/run, retry,
  duplicate idempotency, missed windows, disabled/expired schedules, and
  operator inspection.
- Document the exact clean-break blast radius before changing storage.

### 2. Decision-Backed Schedule Truth

- Represent schedules as `decision` resources with:
  - schedule id;
  - canonical target function/action;
  - cadence/timezone/wall-clock metadata;
  - scope/session/workspace selectors;
  - grant ceiling and actor;
  - expiry/revocation/lifecycle;
  - idempotency and retry policy snapshot.
- Use CAS for schedule updates and lifecycle discard/archive.
- Reject malformed, over-broad, expired, or unauthorized schedules before queue
  enqueue or target execution.

### 3. Invocation/Evidence Run Truth

- Represent each scheduled run as a canonical invocation plus bounded evidence.
- Use deterministic idempotency keys per schedule version and due bucket.
- Ensure retries replay or resume through existing queue/idempotency substrate
  without duplicate target invocations or resource versions.
- Record skipped, stale, malformed, unauthorized, and failed runs as evidence
  without fabricating success.

### 4. Generated Operator Surfaces

- Add generated schedule collection/detail surfaces over decision/evidence truth.
- Stored actions may target only canonical cron/schedule capabilities,
  `ui::refresh_surface`, and safe inspect/retry/expire/archive operations.
- Surfaces must be revision-pinned, bounded, redacted, and stale-safe.
- iOS remains a thin renderer/client; fixed cron/product shells stay removed.

### 5. Clean-Break Removal Or Accepted-Substrate Decision

- If conversion is completed, remove active `cron_jobs`, `cron_runs`, and
  `automations.json` product truth with a storage generation reset and absence
  tests.
- If any scheduler substrate must remain, document it as low-level substrate
  with strict limits and static gates proving it cannot own product policy,
  grants, durable run results, or operator truth.

### 6. Docs, Score, And Ledger

- Update `docs/capability-backed-truth-migration-plan.md`.
- Update `docs/modular-engine-cleanup-audit.md`.
- Update `docs/product-shell-reachability-map.md` only if client surfaces change.
- Update `docs/production-grade-rubric.md`.
- Update README database/capability sections if schema or public capability
  wording changes.
- Update `~/LEDGER.jsonl` after verification.

## Test Plan

- Focused Rust tests:
  - schedule create/update/delete/list use decision/resource truth;
  - run/retry uses deterministic invocation/evidence truth;
  - duplicate due buckets do not create duplicate invocations/resources;
  - expired/revoked/stale schedules fail closed;
  - malformed schedules are inspectable but not runnable.
- Generated UI tests:
  - schedule surfaces expose bounded refs and stored canonical actions only;
  - stale/expired/damaged surfaces fail before child execution.
- Static gates:
  - no active cron/scheduler product tables if converted;
  - no `automations.json` product truth if converted;
  - no `control::act`, dynamic UI catalog, raw-scope auth, compatibility reader,
    fallback DTO, or client-owned scheduler policy.
- Verification:
  - focused cron/scheduler tests;
  - `cargo test generated_ui --lib -- --nocapture` if surfaces change;
  - `cargo test resource_ --lib -- --nocapture` if resource contracts change;
  - `cargo test --test threat_model_invariants -- --nocapture`;
  - `RUSTFLAGS="-D warnings" cargo check --all-targets`;
  - `git diff --check`;
  - `scripts/tron ci fmt check clippy test`;
  - iOS/Mac targeted tests only if client/project files change.

## Acceptance Criteria

- Scheduled-work product truth is reconstructable from collapsed substrate truth,
  or cron is explicitly accepted as low-level substrate with proof.
- Every scheduled run has invocation/evidence lineage.
- Operators can inspect stale, skipped, failed, completed, and retried runs.
- No hidden scheduler file/table truth affects agent behavior.
- The capability-backed-truth score only reaches `99/100` or `100/100` after
  tests, docs, static gates, full CI, and ledger update pass.

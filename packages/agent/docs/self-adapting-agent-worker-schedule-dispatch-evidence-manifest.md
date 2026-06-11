# Self-Adapting Agent Worker Schedule Dispatch Evidence Manifest

Status: **complete**

Baseline: `d701655306bc0ac42ce12a8142ad2a62b6ea0d1b`

## Row Evidence

| Row | Status | Evidence | Verification | Residual Risk |
|---|---|---|---|---|
| SAAWSD-0 | passed_after_fix | Added scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, and local/GitHub static-gate wiring. | `self_adapting_agent_worker_schedule_dispatch_invariants::saawsd_docs_readme_and_ci_are_linked`. | Whole-repo HRA/PCC/TPC/TMB/SACB inventory rows are current after staging. |
| SAAWSD-1 | passed_after_fix | Source inventory covers scheduler ownership, trigger dispatch, autostart validation, activation issue, SAAWBH vault, stdin launch, queue/lease resources, replay, and forbidden surfaces. | `saawsd_scorecard_and_inventory_are_complete`. | Inventory is static and intentionally conservative. |
| SAAWSD-2 | passed_after_fix | `worker_schedule_plan` resource type now rejects arbitrary top-level fields, and `WorkerSchedulePlan` parser enforces reviewed status, UTC-only anchor, 60s..24h interval bounds, fixed v1 policies, trigger/autostart references, and secret-looking value rejection. | Runtime negative tests and static resource-contract gates. | JSON schema handles structure; runtime parser owns semantic checks. |
| SAAWSD-3 | passed_after_fix | SAASTC removed `EngineWorkerScheduleService` and server-start schedule polling; explicit runtime tests still prove schedule dispatch, replay, missed-tick collapse, overlap evidence, and negative validation. | `self_adapting_agent_worker_schedule_dispatch_invariants::saawsd_tests_cover_explicit_dispatch_replay_and_negative_paths`. | There is no production cadence owner after cleanup; any future scheduler loop requires a successor scorecard. |
| SAAWSD-4 | passed_after_fix | `due_tick` computes nominal UTC ticks from anchor plus interval multiples; missed intervals create one `skipped_missed` audit record and enqueue only the latest due tick. | `worker_schedule_dispatch_skips_missed_ticks_without_backfill_storm`. | Exact missed count is audit metadata, not a backfill instruction. |
| SAAWSD-5 | passed_after_fix | Scheduler calls `trigger::dispatch` with enqueue delivery and deterministic target idempotency; it never calls activation issue, vault consume, supervisor, or process-start APIs. | Static no-direct-call invariant plus due/queue drain test. | Trusted internal scope is engine-owned and not provider supplied. |
| SAAWSD-6 | passed_after_fix | Tick id hashes schedule id plus nominal UTC timestamp; replay returns the existing tick/receipt; active prior queue/process evidence records `skipped_overlap`. | Replay and overlap focused tests. | Queue/process evidence remains best-effort durable state inspection. |
| SAAWSD-7 | passed_after_fix | `worker_schedule_tick` stores ids, nominal time, status, queue receipt, dispatch invocation id, idempotency fingerprint, trace id, overlap/missed evidence, and redacted errors only. | Safe-payload assertions and schema/static gates. | Tick payload intentionally stores non-secret ids. |
| SAAWSD-8 | passed_after_fix | No provider-visible tool, public transport method, deploy change, iOS setting, launchd/SMAppService path, restart loop, retry loop, repo skill directory, or payload replay was added. | Static forbidden-surface checks. | Future surfaces must update this gate before merge. |
| SAAWSD-9 | passed_after_fix | Focused negatives fail closed before enqueue for wrong targets, non-enqueue triggers, malformed UTC anchors, interval bounds, unreviewed plans, missing grants, non-stdin launches, and secret-looking values. | `worker_schedule_dispatch_rejects_invalid_plans_before_enqueue`. | Some malformed payloads fail at resource create; runtime covers semantic failures. |
| SAAWSD-10 | passed_after_fix | New runtime instance over the same host replays existing tick and queue receipt without a second queue item, activation, vault consume, or worker launch. | `worker_schedule_dispatch_replays_same_tick_after_restart_without_duplicate_launch`. | In-memory restart simulation proves host-state replay; SQLite durability is covered by existing resource/queue stores. |
| SAAWSD-11 | passed_after_fix | Closeout commands include focused SAAWSD/SAAWTL/SAAWBH/SAAWO/SAAWA tests, all predecessor invariants, primitive trace, integration, full CI, personal-info guard, iOS project drift, and git hygiene. | Final closeout log in commit/final response. | Full CI duration is high; focused tests were used while iterating. |

## Verification Notes

- `worker_schedule_dispatch_enqueues_and_drains_trigger_launch_once` proves a reviewed due schedule creates one tick, one queued trigger dispatch, and one existing SAAWTL worker process start.
- `worker_schedule_dispatch_replays_same_tick_after_restart_without_duplicate_launch` proves duplicate polling or a recreated runtime reuses the same tick/queue result.
- `worker_schedule_dispatch_records_overlap_without_second_enqueue` proves a ready prior queue item is active evidence and blocks another enqueue.
- `worker_schedule_dispatch_rejects_invalid_plans_before_enqueue` proves schedule preflight rejects invalid bindings and secret-looking values before dispatch.
- The SAASTC teardown pass closed the top-level schedule plan schema while
  retaining explicit optional `metadata`, so future schedule fields require a
  schema/docs/test change instead of slipping through as undeclared payload.

## Relationship To Predecessor Campaigns

- SAAWA remains the only activation issuance and readiness contract.
- SAAWO remains the only direct-exec process supervision contract.
- SAAWBH remains the only live activation-bundle custody and stdin handoff contract.
- SAAWTL remains the only trigger-created worker launch path.
- SAAWSD adds reviewed wall-clock schedule-to-trigger dispatch over those paths; it does not duplicate activation, vault, process, or readiness behavior.
- SAAWSC is the successor capacity slice for bounded, resumable scanning of
  reviewed schedule plans; it does not change this dispatch contract.

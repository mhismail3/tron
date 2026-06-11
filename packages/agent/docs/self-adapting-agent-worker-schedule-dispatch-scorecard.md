# Self-Adapting Agent Worker Schedule Dispatch Scorecard

Status: **complete**

Current score: **100/100**

Baseline commit: `d701655306bc0ac42ce12a8142ad2a62b6ea0d1b`

This scorecard records the retained Self-Adapting Agent Worker Schedule Dispatch (SAAWSD) contract after SAASTC cleanup: an explicit schedule runtime can record reviewed UTC fixed-interval ticks and dispatch them through the trusted `trigger::dispatch` path into `worker::launch_from_trigger`. Server startup no longer spawns an autonomous schedule polling service. The runtime never issues activations, consumes vault bundles, supervises processes, or starts workers directly.

SAAWSD deliberately does not add provider-visible schedule tools, public `/engine` schedule APIs, deploy changes, iOS settings, launchd/SMAppService integration, restart loops, retry policy beyond queue mechanics, repo-managed skills, cron/RRULE/local-time scheduling, or post-ready payload replay.

| Row | Outcome | Weight | Status | Evidence |
|---|---|---:|---|---|
| SAAWSD-0 | Harness and Baseline | 5 | passed_after_fix | Started from SAAWTL base commit `d701655306bc0ac42ce12a8142ad2a62b6ea0d1b`; added SAAWSD scorecard, evidence, inventory docs/TSV, invariant target, README links, and CI wiring. |
| SAAWSD-1 | Source Inventory | 5 | passed_after_fix | Inventory covers scheduler ownership, trigger dispatch, autostart plans, activation issue, vault, launch, queue, leases, resources, replay, and forbidden surfaces. |
| SAAWSD-2 | Reviewed Schedule Plan Contract | 10 | passed_after_fix | Added closed top-level `worker_schedule_plan` schema and runtime parser requiring reviewed lifecycle, UTC anchor, interval bounds, trigger/autostart binding, fixed v1 policies, and recursive secret-looking value rejection. |
| SAAWSD-3 | Explicit Scheduler Ownership | 10 | passed_after_fix | SAASTC removed the transport autostart poller; retained tests exercise explicit schedule dispatch and prove server startup does not spawn `EngineWorkerScheduleService`. |
| SAAWSD-4 | Due Tick Calculation | 8 | passed_after_fix | Runtime computes UTC fixed-interval nominal ticks from `anchorAtUtc + n * intervalMs`, dispatches only the latest due tick, and records one skipped-missed audit record. |
| SAAWSD-5 | Trigger Dispatch Composition | 12 | passed_after_fix | Scheduler invokes only `trigger::dispatch` with enqueue delivery and deterministic target idempotency; `worker::launch_from_trigger` remains the only worker launch target. |
| SAAWSD-6 | Idempotency and Overlap | 10 | passed_after_fix | Deterministic tick ids and resource leases replay existing tick/queue state; active prior tick evidence records `skipped_overlap` without another queue item or process start. |
| SAAWSD-7 | Tick Audit Resource | 8 | passed_after_fix | Added `worker_schedule_tick` resource storing schedule/trigger/autostart ids, nominal tick, status, queue receipt, invocation id, key fingerprint, trace, and redacted failure only. |
| SAAWSD-8 | Boundary Hardening | 8 | passed_after_fix | Static gates assert no provider/public/deploy/iOS/launchd/SMAppService/repo-skill/restart/retry/payload-replay surface is introduced. |
| SAAWSD-9 | Negative Validation | 8 | passed_after_fix | Focused tests reject missing fields, malformed UTC anchor, bad intervals, unsupported policies, unreviewed schedules, wrong targets, non-enqueue triggers, missing grants, non-stdin launch plans, and secret-looking values. |
| SAAWSD-10 | Restart Recovery | 6 | passed_after_fix | Restart simulation reconstructs a new schedule runtime over existing host state and replays the same tick/queue result without another activation or launch. |
| SAAWSD-11 | Regression and Closeout | 10 | passed_after_fix | Closeout requires focused SAAWSD/SAAWTL/SAAWBH/SAAWO/SAAWA tests, predecessor invariants, primitive trace, integration, full CI, hygiene checks, and a clean commit. |

## Closeout Targets

- `packages/agent/src/engine/runtime/worker_schedule/mod.rs`
- `packages/agent/src/engine/runtime/worker_schedule/contracts.rs`
- `packages/agent/src/engine/runtime/worker_schedule/tick_dispatch.rs`
- `packages/agent/src/engine/runtime/worker_schedule/overlap.rs`
- `packages/agent/src/engine/durability/resources/worker_schedule_definitions.rs`
- `packages/agent/src/engine/tests/runtime/worker_schedule_dispatch.rs`
- `packages/agent/src/engine/tests/runtime/worker_schedule_dispatch_support.rs`
- `packages/agent/tests/self_adapting_agent_worker_schedule_dispatch_invariants.rs`

## Residual Risks

- Schedules are fixed UTC intervals only. Calendar, timezone, cron, RRULE, jitter, and expiry semantics remain out of scope.
- A reviewed schedule depends on an already-reviewed SAAWTL autostart and launch plan. Runtime revalidates those dependencies before every dispatch.

# Self-Adapting Agent Worker Schedule Dispatch Inventory

Status: SAAWSD campaign `complete`; inventory aligned to the governed schedule-to-trigger dispatch scorecard.

This inventory covers the reviewed schedule contract, engine-owned cadence service, tick audit resources, queue/lease/idempotency replay, trigger dispatch composition, inherited SAAWTL/SAAWBH/SAAWO/SAAWA surfaces, and explicit forbidden boundaries.

## Surface Taxonomy

- `schedule_plan`: reviewed `worker_schedule_plan` schema, parser, policy, UTC interval bounds, and secret rejection.
- `schedule_runtime`: `EngineWorkerScheduleRuntime` due-tick computation, lease guard, replay, overlap, skipped-missed, and trigger dispatch call.
- `schedule_service`: transport-owned background service, cancellation, fixed cadence, and runtime task wiring.
- `tick_audit`: `worker_schedule_tick` resource schema and safe payload builder.
- `trigger_dispatch`: inherited trusted trigger dispatch and enqueue handoff.
- `autostart_plan`: inherited SAAWTL reviewed autostart plan validation.
- `activation_issue`: inherited SAAWA activation issue path.
- `vault`: inherited SAAWBH live activation bundle custody.
- `stdin_launch`: inherited SAAWO/SAAWBH direct-exec stdin launch path.
- `queue_lease_replay`: engine queue, resource lease, idempotency, restart/replay, and process-state evidence.
- `forbidden_surface`: provider/public/deploy/iOS/launchd/restart/retry/repo-skill/payload-replay denial surfaces.
- `closeout_gate`: docs, tests, README, CI, and static invariant wiring.

## Boundary Summary

`worker_schedule_plan` resources are reviewed, UTC-only fixed-interval plans. The scheduler computes the due nominal tick, creates a safe `worker_schedule_tick`, acquires a narrow schedule dispatch lease, and invokes `trigger::dispatch` with `deliveryMode: "enqueue"` and a deterministic target idempotency key derived from schedule id plus nominal UTC timestamp.

The scheduler never calls `worker::issue_activation`, activation bundle vault consume APIs, `worker::launch_activation`, supervisor methods, or process-start APIs directly. SAAWTL remains responsible for activation issue and launch after the queued trigger dispatch drains.

## Residual Risks

- Large schedule-set scan capacity is owned by the successor SAAWSC scorecard.
  This SAAWSD inventory remains focused on the schedule-to-trigger dispatch
  contract.
- Overlap evidence uses persisted queue/process state. If a future process terminal-state writer changes lifecycles, this inventory and tests must change together.
- The TSV is a static inventory. New source files touching these surfaces must add rows and keep the invariant gate current.

# Self-Adapting Agent Worker Trigger Launch Inventory

Status: SAAWTL campaign `complete`; inventory aligned to the trigger-created worker launch scorecard.

This inventory covers the governed internal trigger-to-launch bridge. It includes trusted trigger dispatch, reviewed autostart plans, activation issue, SAAWBH vault custody, stdin launch, attempt audit, replay surfaces, and explicit forbidden surfaces.

## Surface Taxonomy

- `trigger_dispatch`: trigger registration/dispatch code that supplies trusted trigger causal context and target idempotency.
- `autostart_plan`: reviewed `worker_autostart_plan` schema and runtime parser.
- `trigger_launch_runtime`: `worker::launch_from_trigger` orchestration, derived idempotency keys, and preflight checks.
- `activation_issue`: inherited `worker::issue_activation` path used to mint a fresh activation.
- `vault`: inherited SAAWBH process-memory bundle custody.
- `stdin_launch`: inherited `worker::launch_activation` and direct-exec stdin handoff.
- `attempt_audit`: `worker_trigger_launch_attempt` resource schema and payload updates.
- `readiness`: SAAWA hello/register readiness boundary.
- `replay_redaction`: durable ledger/idempotency/replay surfaces that must not persist activation bundles.
- `forbidden_surface`: provider/public API/scheduler/deploy/service-manager/repo-skill denial surfaces.
- `closeout_gate`: docs, tests, README, CI, and static invariant wiring.

## Boundary Summary

`worker::launch_from_trigger` accepts only `autostartPlanResourceId` and optional `launchReason`. The target idempotency key and trigger id must come from causal context supplied by trusted trigger dispatch, and launch timing comes only from the reviewed launch plan. The runtime loads a reviewed autostart plan, validates the registered trigger target is exactly `worker::launch_from_trigger`, preflights the reviewed launch plan for stdin-only delivery, issues activation through `worker::issue_activation`, and launches through `worker::launch_activation`.

Attempts are deterministic and redacted. Duplicate delivery by the same target idempotency key returns the existing attempt/process instead of issuing another activation, consuming another vault entry, or starting another process.

## Residual Risks

- Deterministic worker-id prediction for a reviewed launch plan is a governance-time responsibility. Runtime verifies the plan against the issued activation before process start.
- No automatic retry, restart, scheduler polling, or payload replay exists in this slice.
- The TSV is a static inventory. New source files touching these surfaces must add rows and keep the invariant gate current.

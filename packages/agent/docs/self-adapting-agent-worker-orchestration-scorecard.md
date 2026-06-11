# Self-Adapting Agent Worker Orchestration Scorecard

Current score: **100/100**

Status: **complete**

Baseline commit: `125d58efd7baafb86b2a339d64a6f145b10cc1e2` (`Activate governed external workers`).

This scorecard adds Self-Adapting Agent Worker Orchestration (SAAWO): a host-owned, governed process-supervision bridge for already issued SAAWA activation bundles. It starts only reviewed direct-exec launch plans matched to active `worker_activation` resources, persists redacted `worker_process` audit resources, and relies on the existing `/engine/workers` SAAWA hello plus exact function registration for readiness.

SAAWO deliberately does not add scheduler launch, trigger creation, provider-visible tools, public `/engine` launch messages, deploy flows, launchd/SMAppService integration, automatic restart loops, or repo-managed skills.

Invariant target: `packages/agent/tests/self_adapting_agent_worker_orchestration_invariants.rs`.

| Row | Outcome | Weight | Status | Evidence |
|---|---|---:|---|---|
| SAAWO-0 | Harness and Baseline | 5 | passed_after_fix | Started from `125d58efd`, added scorecard/evidence/inventory artifacts, invariant target, README links, and local/GitHub closeout wiring. |
| SAAWO-1 | Orchestration Source Inventory | 6 | passed_after_fix | Inventory covers activation, launch plans, process resources, supervisor, external-worker runtime, lifecycle streams, grants, transport/provider boundaries, and closeout gates. |
| SAAWO-2 | Launch Plan Resource Contract | 10 | passed_after_fix | Added built-in `worker_launch_plan` schema/lifecycle and runtime validation for direct executable path, digest, argv/env/cwd constraints, expected worker/function/scope/namespace, reviewed governance, and no shell command. |
| SAAWO-3 | Worker Process Resource Contract | 9 | passed_after_fix | Added built-in `worker_process` schema with requested/starting/hello_seen/ready/unhealthy/stopping/stopped/failed/killed/expired/revoked/archived lifecycle states and redacted process/log payloads. |
| SAAWO-4 | Launch Primitive Governance | 11 | passed_after_fix | Added admin `worker::launch_activation` with `worker.launch` authority, high risk, system-ledger idempotency, active activation checks, reviewed launch-plan matching, grant expiry/revocation checks, and fail-closed pre-start validation. |
| SAAWO-5 | Secret Handling | 9 | passed_after_fix | Activation tokens remain unpersisted; supported delivery is `preissued_bundle`; env/log/resource output stores only redacted snippets, env keys, fingerprints, and non-secret activation ids. |
| SAAWO-6 | Supervisor Boundary | 12 | passed_after_fix | Added `WorkerProcessSupervisor` abstraction, production direct-exec supervisor, replaceable fake supervisor tests, bounded stop/kill behavior, no shell, no deploy, no scheduler, no launchd, and no restart loop. |
| SAAWO-7 | Readiness Binding | 10 | passed_after_fix | External-worker runtime updates process to `hello_seen` only after accepted SAAWA hello and `ready` only after exact expected function registration; pre-ready functions remain undiscoverable. |
| SAAWO-8 | Stop, Revoke, and Cleanup | 8 | passed_after_fix | Added admin `worker::stop_process`; stop updates process/activation audit and unregisters volatile catalog entries. Expired/revoked hello rejection marks process terminal; registration mismatch disconnects and fails process audit. |
| SAAWO-9 | Audit and Observability | 6 | passed_after_fix | Process resource transitions and `worker.lifecycle` stream events record requested, starting, hello_seen, ready, stopped, failed, expired, and revoked states with redacted details. |
| SAAWO-10 | No Scheduler / Provider / Public Surface | 6 | passed_after_fix | Static gates prove no public `/engine` launch method, no provider launch tool, no trigger/scheduler launch, no launchd/SMAppService, no deploy command, no repo-managed skills, and no automatic restart loop. |
| SAAWO-11 | Regression and Closeout | 8 | passed_after_fix | Focused worker_orchestration/worker_activation/external_worker tests, SAAWO static invariants, predecessor gates, full CI, personal-info guard, XcodeGen drift check, diff checks, and clean commit are required for closeout. |

Total weight: **100**

## Implementation Notes

- SAAWA activation bundles intentionally return the activation token once and persist only fingerprints. SAAWO therefore supports `preissued_bundle`: the launched process receives non-secret activation identifiers and must already possess the issued bundle out of band. Readiness is still proven only by the existing worker protocol.
- `worker::stop_process` stays under `worker.launch` authority rather than introducing `worker.stop`; the current authority model has no narrower stop scope. A successor slice may split that authority with its own scorecard.
- Process exit monitoring beyond explicit stop is represented by supervisor failures and protocol disconnect/heartbeat cleanup in this slice; scheduler-driven restart or background relaunch is intentionally absent.

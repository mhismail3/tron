# Self-Adapting Agent Worker Trigger Launch Scorecard

Status: **complete**

Current score: **100/100**

Baseline commit: `899910502ec894e1ba8b0c6a5bb0795549383d88`

This scorecard adds Self-Adapting Agent Worker Trigger Launch (SAAWTL): a governed internal bridge from trusted trigger dispatch to reviewed worker autostart. `worker::launch_from_trigger` only runs with trigger causal context, `worker.activate` plus `worker.launch`, and explicit system-ledger idempotency. It loads a reviewed `worker_autostart_plan`, issues a fresh SAAWA activation, leaves the live bundle only in the SAAWBH vault, and launches the reviewed `worker_launch_plan` through `stdin_activation_bundle_v1`.

SAAWTL deliberately does not add wall-clock scheduler polling, provider-visible tools, public `/engine` launch APIs, activation-worker trigger registration, deploy/service-manager paths, launchd/SMAppService, restart loops, post-ready payload replay, or repo-managed skills.

| Row | Outcome | Weight | Status | Evidence |
|---|---|---:|---|---|
| SAAWTL-0 | Harness and Baseline | 5 | passed_after_fix | Started from SAAWBH closeout commit `899910502ec894e1ba8b0c6a5bb0795549383d88`; added SAAWTL scorecard, evidence, inventory docs/TSV, invariant target, README links, and CI wiring. |
| SAAWTL-1 | Source Inventory | 5 | passed_after_fix | Inventory covers trigger dispatch, autostart plan, activation issue, vault custody, stdin launch, attempt audit, replay/export boundaries, and forbidden surfaces. |
| SAAWTL-2 | Reviewed Autostart Plan Contract | 10 | passed_after_fix | Added `worker_autostart_plan` schema and runtime parser requiring reviewed lifecycle, trigger binding, activation fields, reviewed launch plan reference, stdin-only/no-restart/idempotent replay policy, and recursive secret-looking string rejection. |
| SAAWTL-3 | Trigger Launch Primitive | 8 | passed_after_fix | Added admin/internal `worker::launch_from_trigger` with system-ledger idempotency, trigger-causal guard, and both `worker.activate` and `worker.launch` authority scopes. |
| SAAWTL-4 | Activation and Stdin Launch Flow | 12 | passed_after_fix | Trigger launch invokes existing `worker::issue_activation` and `worker::launch_activation` with derived idempotency keys; SAAWA governance and SAAWBH vault/stdin custody remain the only issue/launch paths. |
| SAAWTL-5 | Idempotency and Duplicate Delivery | 10 | passed_after_fix | Deterministic attempt id is derived from autostart plan id, trigger id, and target idempotency key; replay returns the existing attempt/process and focused tests assert no second supervisor start. |
| SAAWTL-6 | Attempt Audit Resource | 8 | passed_after_fix | Added `worker_trigger_launch_attempt` schema and runtime updates for `requested`, `activation_issued`, `launch_starting`, `ready_pending`, and `failed`, storing only ids, fingerprints, status, trace refs, policy, and redacted errors. |
| SAAWTL-7 | Readiness and Failure Semantics | 8 | passed_after_fix | Trigger launch returns process start/ready-pending state only; readiness remains SAAWA hello/register. Issue/launch failures update failed attempts without recovering or replaying activation-bundle material. |
| SAAWTL-8 | Trigger/Worker Boundary Hardening | 8 | passed_after_fix | Existing activation-worker trigger-registration rejection remains intact; static gates assert no provider/public surface and runtime tests reject direct non-trigger calls. |
| SAAWTL-9 | No Scheduler or Restart Loop | 6 | passed_after_fix | Runtime contains no polling interval, scheduler, background watcher, retry loop, restart loop, launchd/SMAppService, service-manager path, or deploy command. |
| SAAWTL-10 | Secret Non-Persistence Audit | 8 | passed_after_fix | SAAWBH vault custody is reused; attempts store only redacted metadata and tests assert activation bundle JSON is absent from attempt/process payloads. |
| SAAWTL-11 | Regression and Closeout | 12 | passed_after_fix | Focused `worker_trigger_launch` tests, SAAWTL invariants, predecessor SAAWA/SAAWO/SAAWBH invariants, primitive trace, integration, full CI, hygiene checks, and clean commit are required for closeout. |

## Closeout Targets

- `packages/agent/src/engine/runtime/worker_orchestration/trigger_launch.rs`
- `packages/agent/src/engine/runtime/worker_orchestration/contracts.rs`
- `packages/agent/src/engine/primitives/worker.rs`
- `packages/agent/src/engine/durability/resources/definitions.rs`
- `packages/agent/src/engine/tests/runtime/worker_orchestration.rs`
- `packages/agent/tests/self_adapting_agent_worker_trigger_launch_invariants.rs`

## Residual Risks

- A reviewed launch plan must know the deterministic activation worker id for the derived trigger issue idempotency key. Runtime fails closed before process start if the reviewed plan and issued activation disagree.
- This slice supports trigger-created launch only. Automatic scheduling, retries, restart policy, and post-ready payload replay remain explicitly out of scope.

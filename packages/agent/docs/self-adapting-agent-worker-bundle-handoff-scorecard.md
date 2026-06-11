# Self-Adapting Agent Worker Bundle Handoff Scorecard

Current score: **100/100**

Status: **complete**

Baseline commit: `2d3cf28eb130bcf6ba22b59b55556ba22abea650` (`Orchestrate governed worker launches`).

This scorecard adds Self-Adapting Agent Worker Bundle Handoff (SAAWBH): secure, ephemeral activation-bundle custody and one-shot stdin delivery for SAAWO-launched local workers. Live `worker::issue_activation` still returns the activation bundle to the immediate admin/internal caller, but durable invocation rows, idempotency outcomes, replay exports, resources, streams, queues, process payloads, logs, env, and argv retain only redacted metadata.

SAAWBH deliberately does not add scheduler launch, trigger-created launch, provider-visible tools, public `/engine` handoff APIs, deploy flows, launchd/SMAppService integration, automatic restart loops, or repo-managed skills.

Invariant target: `packages/agent/tests/self_adapting_agent_worker_bundle_handoff_invariants.rs`.

| Row | Outcome | Weight | Status | Evidence |
|---|---|---:|---|---|
| SAAWBH-0 | Harness and Baseline | 5 | passed_after_fix | Started from SAAWO closeout commit `2d3cf28e`; added scorecard, evidence, inventory docs/TSV, invariant target, README links, and local/GitHub CI wiring. |
| SAAWBH-1 | Source Inventory | 5 | passed_after_fix | Inventory covers activation issue, vault, durable ledger/idempotency redaction, delivery modes, supervisor stdin, process resources, replay export, and static gates. |
| SAAWBH-2 | Durable Result Redaction | 12 | passed_after_fix | `worker::issue_activation` durable rows and idempotency outcomes store a narrow redacted activation-bundle shape with ids, expiry, token fingerprint, and expected function metadata only. |
| SAAWBH-3 | Ephemeral Bundle Vault | 12 | passed_after_fix | Added process-memory `WorkerActivationBundleVault`, keyed by activation resource id, TTL-bound, metadata-inspectable, and one-shot consumable with no SQLite/resource/stream backing. |
| SAAWBH-4 | Issue Activation Integration | 9 | passed_after_fix | Activation issue stores the live bundle in the vault before returning it; idempotent replay returns the redacted durable result rather than the original secret. |
| SAAWBH-5 | Launch Plan Delivery Contract | 9 | passed_after_fix | `worker_launch_plan.activationDeliveryMode` supports `preissued_bundle` and `stdin_activation_bundle_v1`; launch validation rejects secret-looking env/argv/cwd/path/policy material. |
| SAAWBH-6 | Supervisor Stdin Boundary | 12 | passed_after_fix | Production supervisor uses direct exec with piped stdin only, writes once, closes stdin, and stores only fingerprint/count/redaction metadata. |
| SAAWBH-7 | Launch/Handoff Governance | 9 | passed_after_fix | `worker::launch_activation` consumes an unexpired matching vault bundle once for stdin mode; idempotent launch replay returns the existing process without second consume/start. |
| SAAWBH-8 | Secret Non-Persistence Audit | 10 | passed_after_fix | Focused tests and static gates prove activation bundles are redacted in durable results and process resources; fake supervisor records only safe stdin metadata. |
| SAAWBH-9 | Readiness and Failure Semantics | 6 | passed_after_fix | Existing SAAWA hello/register readiness remains authoritative; failed starts after consume mark process failed with redacted handoff metadata only. |
| SAAWBH-10 | No New Public/Scheduler Surface | 5 | passed_after_fix | Static gates prove no provider handoff tool, public `/engine` handoff API, trigger scheduler, deploy flow, launchd/SMAppService, restart loop, or repo-managed skill. |
| SAAWBH-11 | Regression and Closeout | 6 | passed_after_fix | Focused SAAWBH/SAAWO/SAAWA tests, predecessor invariants, primitive trace, integration, full CI, hygiene checks, and clean commit are required for closeout. |

Total weight: **100**

## Implementation Notes

- Server restart loses unconsumed activation bundles by design. The safe recovery path is issuing a new activation.
- Failed supervisor start after stdin consume does not restore or persist the bundle.
- `preissued_bundle` remains supported for existing SAAWO callers.

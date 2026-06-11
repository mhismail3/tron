# Self-Adapting Agent Worker Orchestration Inventory

Status: SAAWO campaign `complete`; launch orchestration source inventory and closeout coverage are tracked in the TSV companion.

Scorecard: [`self-adapting-agent-worker-orchestration-scorecard.md`](self-adapting-agent-worker-orchestration-scorecard.md)

Machine-readable inventory: [`self-adapting-agent-worker-orchestration-inventory.tsv`](self-adapting-agent-worker-orchestration-inventory.tsv)

## Surface Classes

- `closeout_gate`: scorecard, evidence, inventory, static invariant target, README, scripts, and CI wiring.
- `activation_binding`: SAAWA activation resource, grant/token validation, and expected function metadata binding reused by orchestration.
- `launch_plan`: reviewed `worker_launch_plan` resource schema, direct exec policy, digest/path/argv/env/cwd validation, and governance chain.
- `process_resource`: `worker_process` lifecycle, redacted payload, pid fingerprint, exit/log/readiness audit, and activation linkage.
- `supervisor`: direct-exec process abstraction, fake supervisor tests, bounded stop/kill behavior, and no shell/restart/deploy surface.
- `readiness_binding`: existing `/engine/workers` hello/register path, volatile catalog cleanup, proxy invocation after readiness, and mismatch handling.
- `transport_boundary`: public `/engine`, provider, scheduler, trigger, launchd/SMAppService, deploy, and repo-managed skill boundaries.
- `regression_gate`: predecessor scorecard gates and closeout command coverage.

## Scope

SAAWO covers manual/admin launch and stop of local worker processes for already issued SAAWA activation bundles. It does not deliver or persist activation tokens. The supported launch delivery mode is `preissued_bundle`; the worker must possess its issued activation bundle out of band and prove readiness through the existing loopback worker protocol.

No scheduler-driven launch, trigger registration, automatic restart loop, provider-visible tool, public `/engine` launch method, deploy command, launchd/SMAppService integration, or repo-managed skill surface is part of this inventory.

## Closeout State

No open SAAWO rows remain. Residual risks and final verification commands are recorded in the evidence manifest. Future scheduler/autostart, token-delivery, or service-management work requires a successor scorecard and new inventory rows.

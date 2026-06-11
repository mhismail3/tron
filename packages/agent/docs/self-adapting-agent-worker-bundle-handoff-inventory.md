# Self-Adapting Agent Worker Bundle Handoff Inventory

Status: SAAWBH campaign `complete`; activation-bundle handoff source inventory and closeout coverage are tracked in the TSV companion.

Scorecard: [`self-adapting-agent-worker-bundle-handoff-scorecard.md`](self-adapting-agent-worker-bundle-handoff-scorecard.md)

Machine-readable inventory: [`self-adapting-agent-worker-bundle-handoff-inventory.tsv`](self-adapting-agent-worker-bundle-handoff-inventory.tsv)

## Surface Classes

- `closeout_gate`: scorecard, evidence, inventory, static invariant target, README, scripts, and CI wiring.
- `activation_issue`: `worker::issue_activation`, resource fingerprint storage, vault custody, and one-time replay semantics.
- `durable_redaction`: invocation ledger, idempotency outcome, and replay/export redacted activation-bundle shape.
- `vault`: process-memory activation bundle custody, metadata inspection, TTL purge, and one-shot consume.
- `launch_plan`: delivery mode validation and secret-material rejection across env/argv/cwd/path/policy fields.
- `supervisor_stdin`: direct-exec stdin write/close behavior and safe fake-supervisor metadata.
- `process_resource`: `worker_process` handoff audit fields with fingerprint/count/redaction marker only.
- `readiness_binding`: existing SAAWA hello/register readiness and failure semantics.
- `transport_boundary`: public `/engine`, provider, scheduler, trigger, deploy, service-manager, restart-loop, and repo-managed skill boundaries.

## Scope

SAAWBH covers secure activation-bundle custody and stdin handoff for already reviewed SAAWO launches. It does not create launches from triggers, schedules, providers, public handoff APIs, deploy helpers, launchd/SMAppService, restart loops, or repo-managed skills.

No open SAAWBH rows remain. Residual risks and final verification commands are recorded in the evidence manifest. Future scheduler/autostart work requires a successor scorecard and new inventory rows.

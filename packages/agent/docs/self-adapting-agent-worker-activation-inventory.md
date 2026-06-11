# Self-Adapting Agent Worker Activation Inventory

Status: SAAWA campaign `complete`; activation source inventory and closeout
gates are closed for the first worker-activation slice.

Machine-readable inventory:
[`self-adapting-agent-worker-activation-inventory.tsv`](self-adapting-agent-worker-activation-inventory.tsv)

## Surface Classes

- `activation_contract`: primitive contract, request/response schema, authority,
  visibility, idempotency, and admin-only activation surface.
- `governance_chain`: decision/evidence/candidate validation that mirrors SAPG
  promotion governance semantics for activation.
- `resource_contract`: built-in `worker_activation` kind, lifecycle states,
  payload schema, redacted token storage, and resource namespace claims.
- `grant_token`: scoped grant derivation and `ScopedWorkerToken` activation
  metadata.
- `external_runtime`: worker hello, function registration, trigger rejection,
  proxy invocation, disconnect, heartbeat, and runtime lifecycle state.
- `lifecycle_audit`: `worker.lifecycle` stream events plus activation resource
  status updates for connect/register/disconnect/expiry/revoke.
- `transport_boundary`: public `/engine` and provider surfaces that must not
  expose activation methods or tools.
- `closeout_gate`: tests, scorecards, inventories, README, scripts, and CI
  gates that keep the slice wired into local and GitHub validation.

## Coverage Policy

SAAWA covers manual activation material issuance and runtime validation only. A
source path is in scope when it defines `worker::issue_activation`, validates
governance, stores activation resources, derives worker grants, serializes
activation token metadata, accepts external-worker hello/function registration,
updates lifecycle audit state, exposes public/provider surfaces that must not
include activation, or verifies closeout.

The inventory intentionally excludes worker process launch, scheduling, trigger
creation, provider-facing tools, public activation messages, deploy flows, and
repo-managed skills because those are explicitly out of scope for this slice.

## Closeout Notes

No open SAAWA rows remain. Residual risks are versioned in the evidence
manifest: expiry is checked at hello/registration rather than by a background
scheduler, activation v1 is session/workspace only, and future launch/scheduling
work requires a separate scorecard.

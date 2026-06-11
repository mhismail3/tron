# Self-Adapting Agent Worker Activation Scorecard

Branch: `codex/self-adapting-agent-worker-activation`
Baseline commit: `4b530e014 Harden promotion governance`
Status: **complete**
Current score: **100/100**

This scorecard adds the first governed bridge from reviewed
`capability_definition` resources to the existing loopback external-worker
runtime. `worker::issue_activation` issues scoped activation material only after
validating the decision/evidence/candidate chain. The runtime then accepts hello
and function registration only when the activation token, grant, resource, scope,
namespace, metadata, and expected function definition all match.

Invariant target:
`../tests/self_adapting_agent_worker_activation_invariants.rs`.
Tracked test path:
`packages/agent/tests/self_adapting_agent_worker_activation_invariants.rs`.

| Row | Outcome | Weight | Status | Evidence |
|---|---|---:|---|---|
| SAAWA-0 | Harness and Baseline | 6 | passed_after_fix | Started from SAPG closeout commit `4b530e014`, added SAAWA scorecard/evidence/inventory artifacts, README links, and local/GitHub CI wiring. |
| SAAWA-1 | Activation Source Inventory | 7 | passed_after_fix | Inventory covers worker primitive contracts, activation implementation, SAPG-derived governance checks, resource definitions, scoped tokens, grant derivation, external-worker runtime, lifecycle streams, transport boundaries, and static gates. |
| SAAWA-2 | Activation Resource Contract | 10 | passed_after_fix | Added built-in `worker_activation` resource kind with issued/connected/registered/disconnected/expired/revoked/failed/archived lifecycle states, strict refs, scope fields, expected function contract, loopback/volatile policy, and redacted token fingerprint storage. |
| SAAWA-3 | Governance Chain Validation | 13 | passed_after_fix | Activation requires a reviewed `capability_definition`, final accepted decision, accepted verified evidence, matching function/visibility/scope, admin authority for system-scoped governance refs, and linked decision/evidence/candidate chain before issuing material. |
| SAAWA-4 | Scoped Grant and Token Issuance | 13 | passed_after_fix | Derived grants are children of `worker-runtime`, bound to `worker:<workerId>` and subject worker, non-delegating, loopback-only, expiring within 24h, non-wildcard for worker selectors, and limited to the target function plus `stream::publish`. |
| SAAWA-5 | Worker Hello and Registration Binding | 12 | passed_after_fix | `ScopedWorkerToken` carries activation metadata; runtime validates token fingerprint, governance fingerprint, grant hash/lifecycle/expiry, activation resource status, volatile mode, exact namespace/scope, expected function contract, metadata, and one-function limit. |
| SAAWA-6 | Lifecycle and Revocation Audit | 10 | passed_after_fix | Activation resources move through connected, registered, disconnected, expired, and revoked states alongside existing `worker.lifecycle` events; revoked/expired grants fail closed before registration. |
| SAAWA-7 | Runtime Invocation Boundary | 9 | passed_after_fix | Registered activation functions route through the existing external proxy only after registration; before registration they are undiscoverable, and disconnect removes volatile catalog entries. |
| SAAWA-8 | No Launch / No Scheduler / No Provider Surface | 8 | passed_after_fix | Static gates prove activation code has no deploy/spawn/scheduler/autolaunch path, no provider-visible tool, no public `/engine` activation method, and no repo-managed skill surface. |
| SAAWA-9 | Cross-Campaign Regression | 6 | passed_after_fix | SAA, SAPG, SACB, primitive trace, external-worker, and integration targets remain in the closeout set and are run with this slice. |
| SAAWA-10 | Closeout | 6 | passed_after_fix | Focused tests, invariant targets, full local CI, personal-info guard, XcodeGen drift check, whitespace check, ignored-file check, clean status, and commit are completed together. |

## Boundary Statement

Activation v1 is manual, admin/internal, loopback-only, session/workspace scoped,
and function-only. It issues an activation bundle for an already reviewed
capability definition, but it does not spawn workers, schedule triggers, deploy
code, expose a provider-visible tool, add a public `/engine` activation message,
or reintroduce repo-managed skills.

## Activation Contract

`worker::issue_activation` is an admin-visible, idempotent, high-risk host
primitive requiring `worker.activate` and an explicit `idempotencyKey`. The
request names one function, one reviewed capability-definition candidate, one
final accepted decision, one or more accepted verified evidence resources,
target visibility `session` or `workspace`, an activation reason, and an
optional shorter expiry. The response contains the activation resource id,
worker id, expiry, worker hello template, scoped worker token, and expected
function definition. Durable state stores only redacted token fingerprint and
governance references.

## Successor Cleanup Note

SAASTC tightened activation governance after closeout: system-scoped
decision/evidence/candidate resources now require an admin-like actor before
`worker::issue_activation` can use them. This preserves the SAAWA contract while
matching the later promotion-governance authority boundary.

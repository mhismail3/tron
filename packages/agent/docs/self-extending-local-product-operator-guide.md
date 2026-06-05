# Worker-First Local Product Operator Guide

This guide is for contributors and operators proving local worker extension,
Worker Pack lifecycle, generated controls, and audit evidence without adding
remote marketplace or production rollout flows.

## Operating Model

The product model is one orchestrator plus workers. The orchestrator receives
the user request, delegates non-trivial work to Workers or Worker Packs, and
records evidence. The Work dashboard presents progress and health; Audit
Details carries exact protocol and ledger proof.

`capability::execute` remains the single technical Work router for provider
turns. Operator/admin surfaces may inspect specific catalog functions, but
normal autonomous work should flow through execute so preparation, audited
auto-decisions, idempotency, grants, leases, evidence, and child invocations
stay in one ledger.

For local worker creation, fetch `worker::protocol_guide` through execute at
the start of every run. Do not copy protocol fields into docs or skills. Spawn
helpers with `worker::spawn` only after expected function ids, namespace bounds,
resource selectors, file roots, network policy, and authority are explicit.

Resource refs are evidence. Treat resource ids, version ids, invocation ids,
catalog revisions, generated surface ids, source approvals, conformance refs,
and trust evidence as the durable proof for operator decisions.

## Workspace Worker Extension

1. Start from chat or a deterministic test harness with a real
   session/workspace context.
2. Create an audited workspace autonomy grant through
   `self_extension::grant_workspace_autonomy` when hands-off local changes are
   required. Default autonomy is run-unless-blocked; explicit QA testing mode
   may restore interactive prompts.
3. Use the returned workspace id and grant id when invoking `worker::spawn` for
   workspace-visible workers.
4. Watch registration with `catalog::watch_snapshot`, then inspect the worker
   ability with `capability::inspect`.
5. Run focused tests, conformance, and one real invocation before marking the
   worker ready to reuse.
6. Clean up volatile workers with `sandbox::stop_spawned_worker` or worker
   disconnect, and discard helper files only through repository-relative
   worktree actions.

Promotion is a separate explicit operator decision. Creation, repair,
successful invocation, or workspace-local readiness must not imply promotion.

## Local Worker Pack Lifecycle

Local Worker Pack lifecycle operations are canonical module functions:

- `module::register_package` validates a local manifest, digest-pinned
  materialized files, declared worker abilities, config schema, and grant
  ceiling.
- `module::verify_source` records local source evidence and digest checks.
- `module::record_conformance` stores conformance evidence for declared worker
  abilities.
- `module::approve_source` records scoped source approval for unsigned local
  packages when policy requires it.
- `module::configure` validates operator configuration and secret refs.
- `module::activate` starts the local process through the module activation
  path and records activation state.
- `module::disable` stops an activation through the canonical lifecycle.
- `module::rollback` returns an activation to a prior allowed version.
- `module::remove_package` discards the package/config resources after live
  activations are disabled, quarantined, damaged, discarded, or removed.

There is no generic package action multiplexer. Generated module actions are
server-advertised summaries over these canonical functions.

## Generated Controls

Generated pack and worker controls are `ui_surface` resources. Operators may
create or inspect them through `ui::surface_for_target`,
`ui::inspect_surface`, `ui::validate_surface`, and related UI functions.
Clients submit `ui::submit_action` with the stored surface id, version id,
action id, user input, and idempotency key. The server reconstructs the target
work call and enforces approval policy, freshness, grants, leases, and
compensation.

Generated Controls should show preview, diff or summary where relevant, allowed
actions, validation state, and Audit Details links. They must not rely on
target payloads authored by iOS, Mac, or CLI code.

## Trust, Policy, And Routing

Worker Pack trust is derived from source evidence, signatures, approval
decisions, trust roots, revocations, conformance, activation health, and cleanup
state. The server projects plain `trustPresentation` labels for UI display.
Operators should inspect backing evidence before approving source, revoking
approval, or enforcing revocation.

Model routing also stays server-owned. Pack hints may recommend a preset or
worker role, but profile policy chooses what is allowed. Stored events,
agent-result resources, generated lineage UI, and Work events should agree on
the selected preset/model route and any hosted route.

## Boundaries

No remote package discovery exists in these docs or examples. Use local disk
paths, materialized files, local digest-pinned manifests, and local source trust
only. Publishing, rollout, production release, and remote marketplace work stay
outside this operator flow.

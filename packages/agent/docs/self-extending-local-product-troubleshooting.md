# Worker-First Local Product Troubleshooting

Use this guide when worker-led autonomous work, a Worker Pack, Generated
Controls, or a worker route does not reach review-ready evidence.

## Workspace Autonomy Fails Or Pauses

Check that the session has a real workspace id and path, then create the
workspace autonomy grant through `self_extension::grant_workspace_autonomy`.
Default autonomy is run-unless-blocked: approval-required work is recorded as
audited auto-decisions unless a Guardrail blocks it or explicit QA testing mode
is enabled.

If a workspace-visible worker fails with selector errors, inspect the spawn
payload in Audit Details. Approved workspace autonomy can default the child
selector to `workspace:<workspaceId>` when the grant validates, but ordinary
spawns still need explicit bounded selectors.

## Worker Does Not Appear

Fetch the live `worker::protocol_guide` again and compare the helper to the
current protocol. Then check `catalog::watch_snapshot` for the expected
function id and catalog revision. If the worker process exited early, inspect
the spawn invocation, stderr/log evidence, worker token bounds, namespace
claims, and expected function ids in Audit Details.

Use `sandbox::stop_spawned_worker` for cleanup when the worker was launched
through the sandbox path. Stop evidence should show the process stop and the
worker disconnect/unregistration path.

## Materialized Files Or Source Evidence Are Missing

A local Worker Pack manifest should refer to materialized file resources for
the worker entrypoint and any local runtime files. If a materialized file ref
is missing or stale, rerun the materialization path and recompute the package
digest before calling `module::register_package`.

Source verification checks local digest-pinned provenance, materialized file
hashes, and redaction state. Failed source verification should leave evidence
describing the mismatch without creating approval or activation truth.

## Conformance Is Pending Or Failed

Run or record conformance before approving source or activating an unsigned
local Worker Pack. A conformance evidence record should name the package,
declared worker abilities, catalog function ids, worker ids, and result refs.
If conformance fails, repair the owning worker/package file, register or update
the package, and rerun the same failing path before expanding scope.

## Trust Labels Look Wrong

Inspect `trustPresentation` and its backing evidence in Audit Details. Source,
signature, approval, conformance, revocation, promotion, and cleanup labels
should be derived from engine resources, decisions, and evidence. If the UI
label and backing evidence disagree, fix the server projection or decoding path
rather than adding client-side mapping.

## Generated Controls Are Missing Or Disabled

Inspect the target with `ui::surface_for_target` or `ui::inspect_surface`.
The surface should include a current version, validation state, stored action
ids, and resource refs. A stale, expired, damaged, unauthorized, or invalid
surface should fail closed and provide repair guidance.

When submitting actions, use the stored surface/action coordinates. Do not
construct target function ids or payload templates in the client.

## Worker Route Is Unexpected

Start with the selected preset. Local when possible prefers local execution
when profile policy and availability allow it, then records any hosted route.
Balanced and Deep allow different policy tradeoffs. Audit the worker event,
agent-result resource, and generated lineage UI; they should agree on task
profile, selected route, result, and parent/child lineage.

## Local Worker Pack Does Not Activate

For the shipped examples under `packages/agent/examples/local-packs/`, verify
the rendered manifest points at the materialized `worker.py` and
`pack_runtime.py` refs, the computed package digest matches the manifest,
source verification passed, conformance was recorded, source approval exists
when required, and configuration matches the package schema.

Activation should start the local process through `module::activate`. Disable,
rollback, revoke approval, or remove only through canonical module operations
so activation and cleanup evidence remain inspectable.

## Boundary Checks

No remote package discovery, package publishing, production rollout, or remote
pack search should appear in troubleshooting. If a proposed fix requires those
systems, mark it deferred instead of implementing it in the local product flow.

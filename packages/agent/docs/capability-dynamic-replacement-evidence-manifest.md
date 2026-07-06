# Capability Dynamic Replacement Evidence Manifest

Status: **implementation candidate**

This manifest records the source-backed evidence for the first dynamic
replacement slice. The slice adds governed route records and a scoped
`git_status` route seam. It does not claim full autonomous self-update or live
module adapter execution.

## Reviewed Source Files

| Area | File |
|---|---|
| Operation registry | `packages/agent/src/domains/capability/operations/registry.rs` |
| Operation dispatcher | `packages/agent/src/domains/capability/operations/dispatch.rs` |
| Git route seam | `packages/agent/src/domains/capability/operations/git.rs` |
| Provider schema fields | `packages/agent/src/domains/capability/capability_binding_contract.rs` |
| Capability contract guidance | `packages/agent/src/domains/capability/contract.rs` |
| Route service | `packages/agent/src/domains/capability_binding/route.rs` |
| Route authority | `packages/agent/src/domains/capability_binding/authority.rs` |
| Route resource definitions | `packages/agent/src/engine/durability/resources/capability_binding_definitions.rs` |
| Grant authorization | `packages/agent/src/engine/authority/grants/authorization.rs` |
| Modularity inventory | `packages/agent/docs/capability-modularity-inventory.tsv` |
| Canonical README | `README.md` |

## Evidence

| Claim | Evidence |
|---|---|
| Route operations are provider-visible only through `capability::execute`. | Registry and dispatch add `capability_replacement_candidate_*`, `capability_route_binding_*`, `capability_route_activate`, `capability_route_disable`, `capability_route_rollback`, and `capability_route_event_*` operations. |
| Route operations are governance-locked, not adapter-replaceable. | `operation_binding_metadata` and `capability-modularity-inventory.tsv` classify all replacement/route operations as `capability_binding` / `governance_locked`. |
| Kernel and governance operations remain non-routable. | The route service accepts only the first target operation, `git_status`, and the modularity invariants reject binding/rollback seams for locked rows. |
| Candidate records are bounded and provider-safe. | `route.rs` validates unsafe payloads, bounded text/tokens/refs, exact target metadata, route authority, rollback controls, idempotency, and `networkPolicy: none`. |
| Activation is explicit and approval-backed. | `capability_route_activate` requires a ready binding, exact expected binding version, approval refs, rollback/disable controls, exact selectors, and `networkPolicy: none`. |
| Route lookup is exact-scope and fail-closed. | `active_route_for_git_status` derives trusted session/workspace scope, lists active route activations in that scope, verifies binding/candidate refs, skips terminal route events, and returns no route when scope cannot be derived. |
| Routed invocation evidence is durable. | `emit_routed_invocation_event` records a `capability_route_event` resource with route version, activation refs, trace/replay refs, idempotency, and side-effect proof. |
| Current runtime replacement is not overclaimed. | Route annotations set `moduleAdapterInvoked: false`, `moduleAdapterInvocationState: deferred_supervised_runtime_adapter`, and `builtInProjectionUsed: true`. |
| Minimal-engine guardrails hold. | Route records forbid package-manager, network, deploy, dependency restore, dispatch-table mutation, raw paths/commands/logs/code/file contents, raw grant IDs, raw authority IDs, and repo-managed skills. |

## Validation Commands

Focused validation for this slice:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo check --manifest-path packages/agent/Cargo.toml
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml --test capability_modularity_scorecard_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml --test capability_dynamic_replacement_invariants -- --nocapture
CARGO_TARGET_DIR=/tmp/tron-agent-target-dynamic-check cargo test --manifest-path packages/agent/Cargo.toml capability_binding -- --nocapture
scripts/personal-info-guard.sh
git diff --check
git diff --cached --check
```

## Known Gap

The supervised module runtime currently records runtime envelopes and metadata.
It does not yet expose a synchronous provider-safe replacement adapter
projection call that the capability dispatcher can invoke. Until that exists,
the `git_status` route seam annotates the built-in projection with active route
evidence instead of executing a module-owned adapter.

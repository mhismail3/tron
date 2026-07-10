# Engine Capability Pool Evidence Manifest

Status: **passed**

## Reviewed Source

| Area | Source |
|---|---|
| Execute operation registry | `packages/agent/src/domains/capability/operations/operation_contract.rs` |
| Execute catalog bridge | `packages/agent/src/domains/capability/operations/catalog.rs` |
| Capability-pool classification | `packages/agent/src/domains/capability/pool.rs` |
| Domain worker startup registration | `packages/agent/src/domains/registration/mod.rs` |
| Primitive worker startup registration | `packages/agent/src/engine/primitives/workers.rs` |
| Live catalog discovery | `packages/agent/src/engine/catalog/discovery.rs` |
| Engine cockpit projection | `packages/agent/src/domains/capability_binding/cockpit_visibility.rs` |
| iOS cockpit projection | `packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift` |
| iOS cockpit views | `packages/ios-app/Sources/UI/AgentCockpit/` |

## Evidence Added

- `engine-capability-pool-inventory.tsv` lists every current
  `capability::execute` operation and every startup-registered catalog function
  with a surface, audience, replacement class, visibility, authority boundary,
  evidence boundary, minimality decision, and evolution path.
- `capability::pool` exposes the same classification to Rust code so provider
  guidance and UI projections do not depend on a stale freehand document.
- `catalog_search` and `catalog_inspect` annotate catalog functions with
  capability-pool metadata and explicitly guide models toward
  `capability::execute` operations for normal work.
- Invariant tests verify operation coverage, catalog-function coverage, allowed
  replacement classes, visibility policy, and kernel-evolution visibility.

## Validation

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
- `CARGO_INCREMENTAL=0 cargo check --manifest-path packages/agent/Cargo.toml`
- `CARGO_INCREMENTAL=0 cargo clippy --manifest-path packages/agent/Cargo.toml --all-targets -- -D warnings`
- `CARGO_INCREMENTAL=0 cargo test --manifest-path packages/agent/Cargo.toml --lib capability::pool`
- `CARGO_INCREMENTAL=0 cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_search_annotations_bridge_catalog_ids_to_execute_operations`
- `scripts/personal-info-guard.sh`
- `git diff --check`
- tracked ignored-file scan
- no managed `packages/agent/skills`
- independent adversarial review verdict: `slice accepted`
- retained scorecard closeout result: passed, 100/100

## Caveats

- This slice does not add new runtime replacement routes.
- Dynamic external-worker functions are classified at registration/projection
  time rather than pre-listed in the static TSV before they exist.
- Kernel/governance code remains source-evolution-only, not hot-swapped at
  runtime.

# True Modularity Boundary Inventory

Status: **completed**
Scorecard row: `TMB-1`
Last verified: 2026-06-26 (P3MSA-S23A module registry implementation candidate)
Machine-readable inventory: `packages/agent/docs/true-modularity-boundary-inventory.tsv`

This inventory classifies every tracked Rust and Swift source file in the current TMB boundary scope. The TSV remains the source of truth for static coverage; this Markdown file records the dependency rules and approved composition-root exceptions preserved after campaign closeout.

## Dependency Direction Rules

| Class | Rule |
|---|---|
| `facade` | Callers may depend on this narrow owner-approved surface only. |
| `contract` | Types, traits, and DTOs may cross the owning boundary without concrete implementation imports. |
| `adapter` | Boundary translation code may depend inward on contracts and outward on one concrete external backend only. |
| `implementation` | Owner-private behavior; callers must enter through the owner facade or contract. |
| `composition-root` | Dependency assembly points may wire concrete implementations listed here; they must not accumulate reusable domain logic. |
| `test-support` | Test-only helpers; production code must not depend on them. |
| `generated-wire-dto` | Wire/protocol-shaped DTOs; callers should translate before domain or UI logic. |

## Composition Roots

The approved composition roots are:

- Rust server bootstrap under `packages/agent/src/app/bootstrap/`.
- Rust binary entry point `packages/agent/src/main.rs`.
- iOS app lifecycle under `packages/ios-app/Sources/App/`.
- iOS dependency assembly under `packages/ios-app/Sources/Support/Composition/`.

Any other concrete cross-boundary wiring must be promoted into one of these roots or recorded here before it is allowed.

Domain worker registration is owner-local rather than a general composition
root: `packages/agent/src/domains/registration/mod.rs` is the only production
code that may enumerate retained domain worker modules, and it is entered
through `packages/agent/src/transport/runtime/setup.rs`. Individual
`worker_module` constructors and the registration entrypoint stay crate-private.

## Classification Summary

| Class | Files |
|---|---:|
| `adapter` | 139 |
| `composition-root` | 11 |
| `contract` | 105 |
| `facade` | 97 |
| `generated-wire-dto` | 25 |
| `implementation` | 591 |
| `test-support` | 124 |

Total tracked source rows: **1092**.

## Verification

The inventory is checked by `boundary_inventory_covers_tracked_sources` in `packages/agent/tests/true_modularity_boundary_invariants.rs`.

# True Modularity Boundary Inventory

Status: **active**
Scorecard row: `TMB-1`
Machine-readable inventory: `packages/agent/docs/true-modularity-boundary-inventory.tsv`

This inventory classifies every tracked Rust and Swift source file in the active boundary scope. The TSV is the source of truth for static coverage; this Markdown file records the dependency rules and composition-root exceptions used by the campaign.

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

The active composition roots are:

- Rust server bootstrap under `packages/agent/src/app/bootstrap/`.
- Rust binary entry point `packages/agent/src/main.rs`.
- iOS app lifecycle under `packages/ios-app/Sources/App/`.
- iOS dependency assembly under `packages/ios-app/Sources/Support/Composition/`.

Any other concrete cross-boundary wiring must be promoted into one of these roots or recorded here before it is allowed.

## Classification Summary

| Class | Files |
|---|---:|
| `adapter` | 132 |
| `composition-root` | 11 |
| `contract` | 90 |
| `facade` | 85 |
| `generated-wire-dto` | 22 |
| `implementation` | 470 |
| `test-support` | 119 |

Total tracked source rows: **929**.

## Verification

The inventory is checked by `boundary_inventory_covers_tracked_sources` in `packages/agent/tests/true_modularity_boundary_invariants.rs`.

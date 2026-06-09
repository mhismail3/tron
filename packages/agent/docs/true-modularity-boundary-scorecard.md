# True Modularity Boundary Scorecard

Status: **active**
Current score: **28/100**
Branch: `codex/primitive-engine-teardown`

This scorecard formalizes the True Modularity Boundary campaign. The campaign
keeps runtime behavior, wire protocol, product surface, CLI commands, database
schema, and iOS UX stable while tightening module ownership, dependency
direction, and black-box API contracts.

## Boundary Taxonomy

Every tracked Rust and Swift production source must be classified as exactly one
of:

| Class | Meaning |
|---|---|
| `facade` | Narrow owner-approved public surface for a module or domain. |
| `contract` | Types, traits, and DTOs intentionally shared across a boundary. |
| `adapter` | Boundary translation code for providers, transport, SQL, or platform APIs. |
| `implementation` | Owner-private behavior hidden behind facade or contract surfaces. |
| `composition-root` | Dependency assembly point allowed to wire concrete implementations. |
| `test-support` | Fixtures, mocks, or test-only helpers. |
| `generated-wire-dto` | Generated or wire-shaped protocol DTOs owned by protocol boundaries. |

Allowed dependency direction is owner-private implementation -> local contract
or facade -> caller. Adapters translate at the edge. Composition roots may wire
concrete implementations only when listed in the inventory.

## Scorecard

| ID | Objective | Weight | Status | Evidence |
|---|---|---:|---|---|
| TMB-0 | Create the campaign harness | 5 | passed_after_fix | Added this scorecard, the evidence manifest, README links, and `true_modularity_boundary_invariants`; the first invariant run exposes current boundary leaks. |
| TMB-1 | Define boundary taxonomy and inventory | 8 | passed_after_fix | Added `true-modularity-boundary-inventory.md` and `.tsv`; every tracked Rust/Swift source has a class, owner, and dependency-direction row. |
| TMB-2 | Build the model response black box | 15 | passed_after_fix | Added the model-owned `ModelResponder` boundary, moved provider selection/retry/health/error mapping behind it, made provider modules crate-private, removed provider-root re-export veneers, deleted the old agent turn-runner provider helper, and moved canonical token accounting to `domains::model::tokens`. |
| TMB-3 | Narrow engine facade ownership | 12 | open | Engine facade exposure still needs narrowing or justification. |
| TMB-4 | Harden domain worker boundaries | 10 | open | Domain service/internal imports still need guard coverage and cleanup. |
| TMB-5 | Encapsulate state and storage | 10 | open | Store/backend/SQL access still needs owner-private guard coverage and cleanup. |
| TMB-6 | Make transport adapter-only | 10 | open | Transport adapter-only guard coverage and cleanup remain open. |
| TMB-7 | Make iOS Engine access black-boxed | 10 | open | SwiftUI/session access to concrete engine transport and DTOs still needs cleanup. |
| TMB-8 | Define boundary-local error contracts | 8 | open | Provider, SQL, transport, and decoding errors still need boundary mapping guards. |
| TMB-9 | Update docs and README | 6 | open | Final docs and inventory updates are pending later phases. |
| TMB-10 | Final adversarial closeout | 6 | open | Final static scans, focused tests, full CI, personal-info guard, Xcode project drift check, ignored-file check, whitespace check, and clean status are pending. |

Total weight: **100**

## Required Static Guards

The campaign is enforced by
`packages/agent/tests/true_modularity_boundary_invariants.rs`, which owns these
guards:

- `true_modularity_scorecard_stays_formalized`
- `boundary_inventory_covers_tracked_sources`
- `agent_loop_uses_model_responder_boundary`
- `provider_internals_do_not_escape_model_domain`
- `engine_facade_is_the_only_cross_module_engine_api`
- `domain_workers_expose_contracts_not_services`
- `state_stores_are_owner_private`
- `transport_is_adapter_only`
- `ios_ui_uses_repositories_not_engine_transport`
- `boundary_errors_do_not_leak_impl_errors`
- `final_modularity_closeout_is_complete`

Historical evidence may record leaks found during the campaign. Active
scorecard, inventory, and docs must not describe closed leaks as open work after
the phase that closes them.

# Public Protocol API Contract Discipline Inventory

Status: **closed**.

Machine-readable inventory:
[`public-protocol-api-contract-discipline-inventory.tsv`](public-protocol-api-contract-discipline-inventory.tsv)

The TSV contains 12 rows covering the audited public contract markers:
`/engine` transport contracts, transport wire DTOs, public settings DTOs,
settings adapters, transport error mapping, delegated child envelopes, session
event payload ownership, and iOS protocol mirrors. Server/Rust/static proof and
the targeted iOS 26.5 settings protocol validation are complete for the current
scope.

## Closeout State

- Public settings snapshots and updates now use a narrow, versioned DTO instead
  of serializing internal `TronSettings`.
- Public `/engine` request context and delegated child envelopes are guarded
  against trusted runtime metadata and runtime-only catalog/worker internals.
- Transport failure mapping and session event payload ownership remain retained
  through existing typed-envelope tests; iOS decoder runtime verification passed
  after the iOS 26.5 simulator/platform state was repaired.

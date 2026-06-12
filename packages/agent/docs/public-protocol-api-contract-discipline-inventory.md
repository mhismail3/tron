# Public Protocol API Contract Discipline Inventory

Status: **complete**

Machine-readable inventory:
[`public-protocol-api-contract-discipline-inventory.tsv`](public-protocol-api-contract-discipline-inventory.tsv)

## Surface Classes

- `campaign_harness`: PPACD scorecard, evidence, inventory, invariant, README, and CI/static-gate wiring.
- `engine_transport`: Rust `/engine` public method catalog, transport schemas, WebSocket wire messages, dispatch, and socket tests.
- `engine_meta_response`: delegated `engine::invoke` response envelope and child result projection.
- `server_protocol`: shared server protocol, failure, error mapping, and event payload/public stream surfaces.
- `settings_auth_model_session`: public DTOs for settings, auth, model, and session domains.
- `ios_protocol`: iOS protocol DTOs, settings DTOs, failure payloads, and event payload decoders.
- `ios_transport`: iOS WebSocket frame encoders and transport/domain clients.
- `ios_docs`: iOS architecture and event documentation describing the thin-client boundary.
- `predecessor_inventory`: HRA, PCC, TPC, SACB, and OPSAA rows updated so PPACD tracked work is discoverable.

## Coverage Policy

Each row identifies the path, owner, wire direction, versioning behavior,
strictness boundary, authority/idempotency implication, verification evidence,
and PPACD rows. Public protocol surfaces must fail closed when callers try to
mint authority, runtime metadata, hidden worker metadata, or compatibility state
not documented as public wire contract.

## Closeout Notes

This inventory treats Rust decoder strictness, Rust contract metadata, iOS
encoders, and iOS decoders as one parity surface. A server-only denylist is not
enough: public clients must also be unable to construct or preserve internal
control fields as first-class protocol DTOs.

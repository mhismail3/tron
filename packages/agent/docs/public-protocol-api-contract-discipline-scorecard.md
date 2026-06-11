# Public Protocol API Contract Discipline Scorecard

Status: **closed**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/public-protocol-api-contract-discipline`
Base commit: `7411664c4` (`Clean up off-plan successor teardown surfaces`)

Evidence manifest:
[`public-protocol-api-contract-discipline-evidence-manifest.md`](public-protocol-api-contract-discipline-evidence-manifest.md)

Inventory:
[`public-protocol-api-contract-discipline-inventory.md`](public-protocol-api-contract-discipline-inventory.md)
and
[`public-protocol-api-contract-discipline-inventory.tsv`](public-protocol-api-contract-discipline-inventory.tsv)

Invariant target:
[`../tests/public_protocol_api_contract_discipline_invariants.rs`](../tests/public_protocol_api_contract_discipline_invariants.rs)

## Scope

This slice narrows the public `/engine` and `settings::*` contracts, inventories
the server/iOS protocol mirrors, and adds source guards so runtime-only engine
metadata, authority grants, private settings, and raw internal transport errors
do not drift across the public API boundary.

## Scenario Ledger

| Row | Name | Weight | Status | Closure requirement |
| --- | --- | ---: | --- | --- |
| PPACD-0 | Harness | 5 | passed_after_fix | Scorecard/evidence/inventory/invariant target wired into README, local gates, GitHub static gates, and predecessor inventories when relevant. |
| PPACD-1 | Public Surface Inventory | 10 | passed_after_fix | Every public route, public request/response DTO, event payload, settings DTO, transport error shape, and iOS decoder is inventoried with owner, stability decision, and proof target. |
| PPACD-2 | `/engine` Boundary | 15 | passed_after_fix | Public `/engine` transport cannot mint internal scopes, trusted runtime metadata, authority grants, worker-launch/schedule surfaces, or internal-only payloads. |
| PPACD-3 | DTO Stability and Versioning | 10 | passed_after_fix | Version fields or explicit version-stability decisions exist where payload evolution can break clients; unversioned contracts are justified and guarded. |
| PPACD-4 | Server/iOS Parity | 15 | passed_after_fix | Swift decoders and settings/event mirrors compile and pass the targeted iOS protocol test after the shared settings fixture imports the app module it references. |
| PPACD-5 | Error Contract and Redaction | 10 | passed_after_fix | Transport errors are typed, redacted, stable, and do not leak internal state, file paths, secrets, grants, provider internals, or runtime-only metadata. |
| PPACD-6 | Settings/Event Contracts | 10 | passed_after_fix | Settings update DTOs, settings snapshots, event envelopes, session event payloads, and iOS state decoding remain canonical and round-trip guarded. |
| PPACD-7 | Negative/Adversarial Cases | 10 | passed_after_fix | Tests cover malformed payloads, extra fields, missing fields, stale versions, internal leakage attempts, unknown event payloads, and redaction edge cases at the Rust/static source level. |
| PPACD-8 | Docs/README Integrity | 8 | passed_after_fix | README and progressive-disclosure docs reflect actual public contracts only; no stale SAA/OPSTC removed surfaces or aspirational protocol claims. |
| PPACD-9 | Closeout | 7 | passed_after_fix | Focused Rust/static verification, full Rust CI, personal-info guard, XcodeGen drift check, diff checks, and targeted iOS settings protocol validation pass. |

Total weight: **100**

## Closeout Verification

The host iOS 26.5 simulator/platform state was repaired after the initial
blocked checkpoint. The first unblocked iOS compile exposed that
`ServerSettingsFixture` referenced `ServerSettingsContract` without importing
the app module. The fixture now uses the same `@testable import TronMobile`
pattern as other app-dependent fixtures, and the targeted iOS settings protocol
test runs successfully on `iPhone 17 Pro, OS=26.5`.

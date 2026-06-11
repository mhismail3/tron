# Public Protocol API Contract Discipline Evidence Manifest

Status: **closed**
Current score: **100/100**
Branch: `codex/public-protocol-api-contract-discipline`
Base commit: `7411664c4`

Scorecard:
[`public-protocol-api-contract-discipline-scorecard.md`](public-protocol-api-contract-discipline-scorecard.md)

Inventory:
[`public-protocol-api-contract-discipline-inventory.md`](public-protocol-api-contract-discipline-inventory.md)
and
[`public-protocol-api-contract-discipline-inventory.tsv`](public-protocol-api-contract-discipline-inventory.tsv)

Invariant target:
[`../tests/public_protocol_api_contract_discipline_invariants.rs`](../tests/public_protocol_api_contract_discipline_invariants.rs)

## Row Evidence

| Row | Status | Evidence |
| --- | --- | --- |
| PPACD-0 | passed_after_fix | Added PPACD scorecard, evidence manifest, inventory docs/TSV, invariant target path, README link, local closeout entry, GitHub static-gate entry, and predecessor-inventory bookkeeping for new protocol/static-gate marker files. |
| PPACD-1 | passed_after_fix | Inventoried `/engine` contracts, public settings DTOs, settings adapters, transport error mapping, delegated child envelopes, session event payload ownership, and iOS protocol mirrors in the PPACD TSV. |
| PPACD-2 | passed_after_fix | Public invocation context remains limited to session/workspace/trace/parent correlation; iOS no longer encodes `authorityScopes` or `runtimeMetadata`; delegated child responses no longer expose worker/catalog/function revision internals. |
| PPACD-3 | passed_after_fix | Added explicit `contractVersion` to the public settings snapshot/update DTO boundary and rejected stale or missing versions at the server and iOS decode/update boundary. |
| PPACD-4 | passed_after_fix | Server/iOS settings and child-envelope source mirrors are implemented and source-guarded; the targeted iOS settings protocol tests compile and pass after `ServerSettingsFixture` imports the app module whose contract constant it references. |
| PPACD-5 | passed_after_fix | Retained typed canonical transport failure envelope and reran event-store/error-mapping tests that cover typed persistence errors and safe reason mapping. |
| PPACD-6 | passed_after_fix | Replaced direct `TronSettings` serialization in `settings::get`/`settings::reset_to_defaults` with an explicit public snapshot DTO, sparse update adapter, and narrow reset request schema. |
| PPACD-7 | passed_after_fix | Added Rust/static guards for forbidden runtime metadata, child-envelope internal fields, missing/stale settings versions, sparse update behavior, and public settings field exclusion; Swift negative tests for missing/stale settings contract versions now pass in the targeted iOS run. |
| PPACD-8 | passed_after_fix | README, `shared::protocol`, settings module docs, PPACD docs, and SACB inventory now describe the actual public DTO/transport boundaries and local validation state. |
| PPACD-9 | passed_after_fix | Rust/static closeout, personal-info guard, XcodeGen drift check, diff checks, and targeted iOS settings protocol build/test passed. |

## Verification Log

| Command | Result | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed | Rust formatting clean after applying `cargo fmt --manifest-path packages/agent/Cargo.toml --all`. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed | Agent crate compiles; existing provider/engine dead-code warnings remain unrelated to this slice. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | passed | 5 PPACD static invariant tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml transport --lib -- --nocapture` | passed | 65 transport-focused lib tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml shared::protocol --lib -- --nocapture` | passed | 126 shared protocol tests passed, including public settings DTO tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::settings --lib -- --nocapture` | passed | 122 settings-domain tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml event_store --lib -- --nocapture` | passed | 422 event-store/error-mapping tests passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | passed | 17 SACB tests passed after adding the PPACD protocol/static-gate marker files to the SACB inventory. |
| `scripts/tron ci fmt check clippy test` | passed | Broad Rust CI path passed: fmt, check, clippy, and full closeout target set. |
| `scripts/personal-info-guard.sh` | passed | Full source scan found no personal-info leaks. |
| `xcodegen generate` | passed | Regenerated `packages/ios-app/TronMobile.xcodeproj`. |
| `git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | XcodeGen output has no project drift. |
| `git diff --check` | passed | No whitespace/diff marker issues. |
| `git ls-files -ci --exclude-standard` | passed | No tracked ignored files. |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ServerSettingsTests` | blocked_environment | Exits 70 before source compile/test: CoreSimulator `1051.50.0` is older than Xcode's expected `1051.54.0`; no matching simulator device is available. |
| `xcodebuild -scheme Tron -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` | blocked_environment | Exits 70 before source compile: no eligible generic iOS destination; Xcode reports iOS 26.5 platform unavailable despite SDK listing. |
| `xcodebuild -scheme Tron -sdk iphoneos26.5 -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` | blocked_environment | Same destination/platform failure as the generic build attempt. |
| `xcodebuild -license check` | passed | Xcode license is accepted; this was not the local blocker. |
| `xcodebuild -checkFirstLaunchStatus` | blocked_then_passed | Initially exited 69 before the host simulator/platform repair; later exited 0 after iOS 26.5 simulator/platform setup was completed. |
| `sudo -n xcodebuild -runFirstLaunch` | blocked_environment | Non-interactive privileged setup cannot run because sudo requires a password. |
| `xcodebuild -showdestinations -scheme Tron -json` | passed | Confirms an eligible `iPhone 17 Pro` iOS 26.5 simulator destination is now available. |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TronMobileTests/ServerSettingsTests` | failed_then_passed | First unblocked compile failed because `ServerSettingsFixture` referenced `ServerSettingsContract` without importing `TronMobile`; after adding `@testable import TronMobile`, the command passed with 9 Swift Testing tests executed. |

## Residual Risk

No PPACD-specific residual risk remains open in this slice. The public settings
contract, `/engine` public context, delegated child envelope, static guards,
Rust tests, and targeted iOS settings protocol tests are covered by the commands
above. Broader full-iOS regression remains outside this slice's focused
closeout scope.

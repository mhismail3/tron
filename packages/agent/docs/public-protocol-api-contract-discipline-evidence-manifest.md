# Public Protocol API Contract Discipline Evidence Manifest

Status: **complete**
Current score: **100/100**

Scorecard:
[`public-protocol-api-contract-discipline-scorecard.md`](public-protocol-api-contract-discipline-scorecard.md)

Inventory:
[`public-protocol-api-contract-discipline-inventory.md`](public-protocol-api-contract-discipline-inventory.md)
and
[`public-protocol-api-contract-discipline-inventory.tsv`](public-protocol-api-contract-discipline-inventory.tsv)

## Baseline Evidence

| Item | Result |
| --- | --- |
| Branch | `codex/public-protocol-api-contract-discipline-current` |
| Baseline commit | `fccdbbd54161e82bc4c837d68b7c4d0ca62be0cf` |
| Original branch name | Occupied by an incompatible stale local worktree; no merge or wholesale cherry-pick was used. |
| Primary source fix | Rust `/engine` invoke schemas and delegated child response shape were tightened; iOS public invocation context and child decoder were narrowed. |

## Verification Log

| Command | Result | Evidence |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::engine::contracts --lib -- --nocapture` | pass | 4 passed; 0 failed; 2985 filtered out |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::engine::socket::tests --lib -- --nocapture` | pass | 11 passed; 0 failed; 2978 filtered out |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | pass | Formatting check passed after applying `cargo fmt --manifest-path packages/agent/Cargo.toml --all`. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | pass | Check completed; existing dead-code warnings only. |
| `cargo test --manifest-path packages/agent/Cargo.toml transport::engine --lib -- --nocapture` | pass | 19 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml shared::protocol --lib -- --nocapture` | pass | 123 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml shared::server::error_mapping --lib -- --nocapture` | pass | 19 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store::types --lib -- --nocapture` | pass | 70 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | pass | 7 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture` | pass | 6 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | pass | 11 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture` | pass | 9 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture` | pass | 17 passed; 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | pass | 17 passed; 0 failed after PPACD inventory reconciliation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture` | pass | 35 passed; 0 failed after PPACD inventory reconciliation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture` | pass | 16 passed; 0 failed after PPACD inventory reconciliation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture` | pass | 15 passed; 0 failed after PPACD inventory reconciliation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture` | pass | 8 passed; 0 failed after PPACD inventory reconciliation. |
| `cd packages/ios-app && xcodegen generate` | pass | XcodeGen regenerated `TronMobile.xcodeproj`. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TronMobileTests/EngineProtocolBaseTypesTests` | pass | 8 tests executed; 0 failures; includes PPACD public context and child metadata tests. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TronMobileTests/ProtocolConstantsTests` | pass | 8 tests executed; 0 failures. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TronMobileTests/EngineClientErrorTests -only-testing:TronMobileTests/ConnectionStateTests -only-testing:TronMobileTests/EngineStreamScopeTests -only-testing:TronMobileTests/ModelInfoTests` | pass | 8 tests executed; 0 failures. |
| `cd packages/ios-app && git diff --exit-code -- TronMobile.xcodeproj` | pass | Generated project drift check passed after XcodeGen. |
| `scripts/tron ci fmt check clippy test` | pass | Wrapper exited 0; fmt, check, clippy, and test stages completed. |
| `scripts/personal-info-guard.sh` | pass | Full scan passed with no personal-info leaks. |
| `git diff --check` | pass | No whitespace errors. |
| `git ls-files -ci --exclude-standard` | pass | No tracked ignored files. |
| `git status --short` | pass | Slice files were staged before commit. |

## Corrected Verification Findings

- `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TronMobileTests/EngineProtocolTypesTests` returned success but executed 0 tests because the XCTest class is `EngineProtocolBaseTypesTests`. The closure evidence uses the class selector above, which executed 8 tests.
- The original branch name `codex/public-protocol-api-contract-discipline` was held by an incompatible stale local worktree. The fresh current-lineage branch records the authoritative PPACD slice.

## Scorecard Row Evidence

| Row | Status | Evidence |
| --- | --- | --- |
| PPACD-0 | passed_after_fix | Branch/base, docs, invariant, README, local quality, GitHub CI, and predecessor inventory rows were created and validated. |
| PPACD-1 | passed_after_fix | PPACD inventory records Rust, shared protocol, iOS, docs, gates, and predecessor surfaces. |
| PPACD-2 | passed_after_fix | Socket grammar and strict public context decoder tests passed. |
| PPACD-3 | passed_after_fix | Public method set and schema-bearing contracts are guarded by PPACD source checks. |
| PPACD-4 | passed_after_fix | Rust invoke request/context schema and iOS encoded context tests passed. |
| PPACD-5 | passed_after_fix | Rust child response schema/output and Swift child decoder no longer expose worker/catalog revision metadata. |
| PPACD-6 | passed_after_fix | Stream and event surfaces remain covered by transport/event tests and inventory rows. |
| PPACD-7 | passed_after_fix | Settings/auth/model/session DTO surfaces remain inventoried and covered by existing protocol tests. |
| PPACD-8 | passed_after_fix | iOS 26.5 protocol class executed the new public protocol assertions. |
| PPACD-9 | passed_after_fix | Static negative guards passed for internal leakage and wiring drift. |
| PPACD-10 | passed_after_fix | Broad Rust/iOS/local hygiene commands passed before commit. |

## Source Patch Evidence

- `packages/agent/src/transport/engine/contracts.rs` now declares a strict public `invoke` request/context schema and a strict public delegated child response schema.
- `packages/agent/src/engine/invocation/host/meta.rs` no longer serializes worker id, function revision, or catalog revision in delegated child responses.
- `packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift` no longer models authority/runtime public context fields or child worker/catalog revision fields.
- `packages/ios-app/Tests/Engine/Protocol/EngineProtocolTypesTests.swift` now executes public context encoding and child metadata regression tests.

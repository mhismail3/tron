# Configuration / Profile / Environment Discipline Evidence Manifest

Status: **closed**

Current score: **100/100**

This manifest records the closeout suite for the recovery worktree.

## Source Findings

| Finding | Evidence | Resolution |
| --- | --- | --- |
| Stale managed default setting | `packages/agent/defaults/profiles/default/profile.toml` carried `[settings.session] queueDrainMode`, while `SessionSettings` is empty. | Removed stale key; strict unknown-field decode rejects similar drift. |
| Lenient nested settings decode | Several nested `TronSettings` structs used `#[serde(default)]` without `deny_unknown_fields`. | Added `deny_unknown_fields` to nested settings structs that deserialize profile TOML. |
| Non-transactional env override | Invalid `TRON_HEARTBEAT_INTERVAL` was logged and ignored while other env overrides could still apply. | `apply_env_overrides` now parses into a temporary snapshot and returns an error for malformed values. |
| iOS parity audit needed | Swift mirrors only the public `settings::*` surface, not every internal `TronSettings` field. | CPE inventory separates internal settings from public paired-client parity obligations. |
| Cross-slice inventory drift | Predecessor static inventories still referenced moved or newly hardened provider and journal files. | Updated HRA, PRG, PMBD, SOL, TMB, SACB, PCC, and TPC inventories so tracked paths and budgets match the current tree. |

## Command Evidence

| Command | Result |
| --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | PASS |
| `cargo check --manifest-path packages/agent/Cargo.toml` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::settings --lib -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | PASS |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | PASS |
| `scripts/tron ci fmt check clippy test` | PASS |
| `scripts/personal-info-guard.sh` | PASS |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | PASS |
| `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TronMobileTests/ServerSettingsTests` | PASS |
| `cd packages/mac-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/mac-app/TronMac.xcodeproj` | PASS |
| `git diff --check` | PASS |
| `git ls-files -ci --exclude-standard` | PASS |
| `git status --short` | PASS |

## iOS Simulator Rationale

No iOS settings/protocol/UI source files were touched. The slice audited Swift
public-settings parity through static source guards, `xcodegen generate` plus
project-file drift checks passed, and the focused `ServerSettingsTests` suite
passed on `iPhone 17 Pro, OS 26.5`.

## Residual Risk

No CPE residual risk accepted. Existing Rust dead-code warnings are unchanged
and outside this slice.

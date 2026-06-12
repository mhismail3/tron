# iOS Thin Client / Generic Runtime Shell Evidence Manifest

Status: **closed**

Current score: **100/100**

Branch: `codex/ios-thin-client-generic-runtime-shell`

Base commit: `b44a096295f76a2a2a4b00add2d040982b8a73ec`

## Initial Source Audit

| Check | Result | Evidence |
| --- | --- | --- |
| Worktree/base | passed_source_audit | `git status --short` returned no paths; branch switched to `codex/ios-thin-client-generic-runtime-shell`; `git rev-parse HEAD` returned `b44a096295f76a2a2a4b00add2d040982b8a73ec`. |
| Original plan | passed_source_audit | `/Users/<USER>/.codex/attachments/fdc4e780-354b-4da4-8fb5-57839c35bfee/pasted-text.txt` lists ITC as original remaining slice 8. |
| Required iOS docs | passed_source_audit | Read `packages/ios-app/docs/architecture.md`, `development.md`, `events.md`, and `onboarding.md`; they already define the thin-client boundary. |
| iOS roots | passed_source_audit | Source counts: `Sources/App` 2, `Sources/Engine` 132, `Sources/Session` 67, `Sources/Support` 40, `Sources/UI` 134. Required test root counts were also enumerated before edits. |
| Deleted product scan | passed_source_audit | Product-term scan found only existing SourceGuard needles and generic `CapabilityArgumentParserTests` process sandbox argument cases, not retained product panels or clients. |
| iOS 26.5 simulator | passed_source_audit | `xcrun simctl list devices available` shows `iPhone 17 Pro (0AB4FD98-5B16-4B46-927C-5CBBB2FC6A7D)` under iOS 26.5. |

## Required Closeout Command Matrix

Rows record the actual closeout results for this slice. Commands that exposed
source drift are marked `passed_after_fix` and the repair is documented below.

| Command | Status | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed_after_fix | Initial run found rustfmt drift in the new ITC invariant target; `cargo fmt --manifest-path packages/agent/Cargo.toml --all` was applied and the check passed. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed | Completed with existing provider/engine dead-code warnings only. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture` | passed | Final target result after evidence closure: 7 tests passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture` | passed | 9 tests passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture` | passed | 7 tests passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | passed | 5 tests passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | passed_after_fix | SACB inventory rows/count were updated for the new ITC security-marker artifacts; rerun passed 17 tests, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture` | passed | 5 tests passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | passed | 8 tests passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | passed | 2 tests passed, 0 failed. |
| `scripts/tron ci fmt check clippy test` | passed_after_fix | First full run exposed stale HRA marker text; second exposed a personal-info path in this manifest. Both were repaired and the final full CI run passed fmt, check, clippy, and tests with existing provider/engine dead-code warnings. |
| `scripts/personal-info-guard.sh` | passed | Reported `OK - no personal-info leaks in source`. |
| `cd packages/ios-app && xcodegen generate` | passed | Generated `packages/ios-app/TronMobile.xcodeproj` deterministically after adding the Swift SourceGuard file. |
| `cd packages/ios-app && xcodebuild test -project TronMobile.xcodeproj -scheme 'Tron Beta' -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -quiet` | passed_after_fix | Exact iOS 26.5 destination used. One stale guard needle was corrected from the old settings cache symbol to `lastLoadedSettings`; final SourceGuard slice passed. |
| `cd packages/ios-app && xcodebuild test -project TronMobile.xcodeproj -scheme 'Tron Beta' -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' -only-testing:TronMobileTests/PairingURLParserTests -only-testing:TronMobileTests/PairingValidationTests -only-testing:TronMobileTests/PairingPersistorTests -only-testing:TronMobileTests/PairedServerStoreTests -only-testing:TronMobileTests/PairedServerTokenStoreTests -quiet` | passed | Pairing/storage focused slice passed on the exact iOS 26.5 destination. |
| `cd packages/ios-app && xcodebuild test -project TronMobile.xcodeproj -scheme 'Tron Beta' -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' -only-testing:TronMobileTests/SettingsParityTests -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/EngineProtocolTypesSettingsTests -quiet` | passed | Settings parity and server-authority focused slice passed on the exact iOS 26.5 destination. |
| `cd packages/ios-app && xcodebuild test -project TronMobile.xcodeproj -scheme 'Tron Beta' -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' -only-testing:TronMobileTests/ConnectionErrorClassifierTests -only-testing:TronMobileTests/ConnectionManagerTests -only-testing:TronMobileTests/ConnectionToastPolicyTests -only-testing:TronMobileTests/NetworkDiagnosticsFormatterTests -quiet` | passed | Transport retry/toast/diagnostics focused slice passed on the exact iOS 26.5 destination. |
| `cd packages/ios-app && xcodebuild test -project TronMobile.xcodeproj -scheme 'Tron Beta' -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro' -only-testing:TronMobileTests/ErrorEventProjectionTests -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests -only-testing:TronMobileTests/UnifiedEventTransformerTests -only-testing:TronMobileTests/GeneratedUIRendererTests -quiet` | passed | Error projection, generic capability, timeline, and generated renderer focused slice passed on the exact iOS 26.5 destination. |
| `git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | No unstaged generated-project drift after final `xcodegen generate`. |
| `git diff --check` | passed | No whitespace errors. |
| `git ls-files -ci --exclude-standard` | passed | No tracked ignored files. |
| `git status --short` | passed_precommit_staged | Reported only the expected staged ITC slice files before final commit; post-commit clean status is verified in closeout. |

## Validation Repairs

- The SACB invariant initially failed because the new ITC security-marker docs
  and test target were not represented in the SACB inventory/count. The SACB
  inventory and expected count were updated, then the target passed 17/17.
- Full `scripts/tron ci fmt check clippy test` initially failed on a retained
  HRA provenance marker and then on a redaction issue in this manifest. The HRA
  inventory marker was restored and the path was redacted before the final full
  CI pass.
- The iOS SourceGuard simulator slice initially caught a stale settings cache
  needle. The guard now points at the current `lastLoadedSettings` source
  anchor and the SourceGuard test slice passes on iOS 26.5.

## Current Findings

- No iOS production-source rewrite is included in the first checkpoint because
  source inspection did not identify a stale retained panel/client/state object.
- The first iOS change is limited to `SourceGuardTests+ThinClientShell.swift`,
  which proves retained thin-shell anchors and deleted product-boundary absence.
- The simulator destination selected for validation is
  `platform=iOS Simulator,OS=26.5,name=iPhone 17 Pro`.

## Residual Risk

No iOS production source rewrite was justified by the source audit. The residual
risk is future product-specific drift reappearing in iOS source, tests, docs, or
generated project state; the new Swift SourceGuard, Rust ITC invariant,
README/docs links, and HRA/PCC/SACB inventory rows now gate that boundary.

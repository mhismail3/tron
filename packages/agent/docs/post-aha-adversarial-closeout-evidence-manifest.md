# Post-AHA Adversarial Closeout Evidence Manifest

Current score: **79/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

## Summary

This manifest records red/green proof for the post-AHA adversarial closeout
campaign. PAC-0 intentionally adds failing gates before fixes so the closeout
work is driven by executable evidence instead of the external Downloads plan.

## Evidence Table

| ID | Status | Change summary | Verification | Residuals | Commit |
|----|--------|----------------|--------------|-----------|--------|
| PAC-0 | passed_after_fix | Created the scorecard, evidence manifest, README links, and intentionally red static gate target for the PAC findings. | Red proof captured by `cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants -- --nocapture`; see PAC-0 red proof below. | Closed; PAC-1 through PAC-10 own the remaining red gates. | `1d1aa2f34` |
| PAC-1 | passed_after_fix | Removed Mac `git diff --exit-code packages/mac-app/TronMac.xcodeproj` checks from CI/release, added ignored-project existence checks after XcodeGen, kept iOS tracked-project drift checks, and revised the older AHA Xcode policy gate/docs to the split iOS-tracked/Mac-untracked rule. | PAC Mac policy gate, revised AHA Xcode policy gate, and AHA scorecard formalization passed. | Closed; PAC-4/PAC-5 still own Mac source organization and guard breadth. | `e0fe3adb9` |
| PAC-2 | passed_after_fix | Repaired README/AGENTS source-truth paths for settings, auth credentials, protocol events, and path helpers; removed the dead `domains/tools` maintenance row; and made the settings parity instructions name the current iOS owner files. | PAC source-truth path guard passed; stale path scan hits only the guard's banned-needle list. | Closed. | `93a38fc4d` |
| PAC-3 | passed_after_fix | Removed the stale README `context` startup-domain claim and added the missing `engine_catalog_workers`/`engine_catalog_functions` rows to the database table inventory. | PAC runtime/docs parity guard and the primitive SQLite migration table test passed. | Closed. | `62d089682` |
| PAC-4 | passed_after_fix | Split Mac runtime ownership so `LiveLaunchAgentManager` lives under `Server/LaunchAgent`, `Subprocess` lives under `Support/Foundation`, live-manager tests live under `Tests/Server/LaunchAgent`, and `ServerPing.swift` contains only ping/status capture behavior. README and Mac architecture docs now name those owners. | PAC Mac ownership guard passed; Mac XcodeGen regenerated the ignored project; focused Mac ping, launch-agent, install-runner, and fake-manager tests passed. | Closed; PAC-5 still owns guard breadth for roots, helper resources, staged binaries, clean mode, and LOC warnings. | `57fbcf537` |
| PAC-5 | passed_after_fix | Added Mac SourceGuard-style tests for required roots, banned roots, helper-resource layout, staged-binary policy, `bundle-agent --clean`, and 590 LOC warning rows. Narrowed `bundle-agent.sh --clean` so it removes only ignored staged helper binaries, not tracked helper skeletons or LaunchAgent plists. Mac development docs now spell out the clean-mode boundary. | PAC Mac guard static gate passed; `bash -n packages/mac-app/scripts/bundle-agent.sh` passed; XcodeGen regenerated the ignored project; focused `MacSourceGuardTests` passed. | Closed. | `1455a59a9` |
| PAC-6 | passed_after_fix | Moved iOS Retry, WebSocket, and Chat tests into directories that mirror their production owners; expanded `SourceGuardTests+Budgets` to watch `Sources/Engine/Transport/Retry`, `Tests/Engine/Transport/Retry`, `Tests/Engine/Transport/WebSocket`, and the Chat `Coordinators`/`Messaging`/`ViewModel` test roots; updated iOS docs, HRA near-budget rows, and HRA/PCC inventory rows; regenerated the tracked iOS Xcode project. | PAC iOS mirror static gate passed; HRA scorecard formalization passed; HRA/PCC inventory guards passed; iOS XcodeGen passed; focused `SourceGuardTests` and the moved test suites passed on `iPhone 17 Pro`. | Closed. | `efffbbe19` |
| PAC-7 | passed_after_fix | Added progressive disclosure sections to top-level Rust `mod.rs` roots for `app`, `domains`, `engine`, `shared`, and `transport`; added the current 895 LOC concrete split-plan watch row for `packages/agent/src/engine/catalog/registry/mod.rs`. | PAC Rust docs/LOC static gate passed; Rust formatting check passed; rustdoc with denied warnings passed; whitespace check passed. | Closed. | `8e2221f74` |
| PAC-8 | pending | Pending. | Pending. | Local/GitHub CI parity still needs PAC target wiring. | pending |
| PAC-9 | pending | Pending. | Pending. | AHA provenance, privacy scope, and residue wording policy still need durable proof. | pending |
| PAC-10 | pending | Pending. | Pending. | Final closeout verification has not run. | pending |

## PAC-0 Red Proof

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants -- --nocapture
```

Result: exit 101 on 2026-06-08. The target compiled without warnings and ran
10 tests: 1 passed and 9 failed intentionally.

Expected setup proof:

- `post_aha_adversarial_closeout_scorecard_stays_formalized`

Expected red findings:

- `mac_generated_project_policy_is_truthful`: Mac generated project policy is
  still asserted as a tracked diff in older workflows/gates.
- `documented_source_truth_paths_exist_or_use_supported_globs`: README/AGENTS
  still contain stale canonical source paths.
- `startup_domains_and_database_inventory_match_runtime_truth`: README still
  claims startup registers `context`, and database docs need full runtime table
  parity.
- `mac_launch_agent_and_subprocess_have_physical_owners`: launch-agent and
  subprocess code still live under `Server/Health`.
- `mac_source_guards_cover_wrapper_contracts`: Mac SourceGuard-style tests do
  not yet exist.
- `ios_transport_and_chat_tests_mirror_production_owners`: Retry/WebSocket and
  Chat tests are not fully mirrored under production-owner folders.
- `rust_progressive_docs_and_loc_split_plans_are_current`: top-level Rust docs
  and 890+ LOC split-plan rows need expansion.
- `local_and_github_ci_run_the_same_static_closeout_targets`: local and GitHub
  test target lists are not aligned and do not yet include PAC.
- `aha_provenance_privacy_and_residue_policy_are_in_repo`: AHA plan provenance,
  privacy scan scope, and fallback/compatibility wording policy need durable
  in-repo proof.

## Residual Risk Log

- PAC-8 through PAC-10 remain open. No row will be marked complete until its
  guard, docs, targeted verification, and evidence are green.

## PAC-7 Verification

Completed Rust docs and LOC budget repair:

- `packages/agent/src/app/mod.rs`
- `packages/agent/src/domains/mod.rs`
- `packages/agent/src/engine/mod.rs`
- `packages/agent/src/shared/mod.rs`
- `packages/agent/src/transport/mod.rs`

Each top-level root now has `## Submodules`, `## Entry Points`,
`## Invariants`, and `## Test Ownership` sections. The PAC watchlist has a
current row for the only tracked Rust/Swift file at or above 890 LOC:
`packages/agent/src/engine/catalog/registry/mod.rs` at 895 LOC, with a concrete
split plan.

Focused proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants rust_progressive_docs_and_loc_split_plans_are_current -- --nocapture
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
RUSTDOCFLAGS='-D warnings' cargo doc --manifest-path packages/agent/Cargo.toml --no-deps
git diff --check
```

Result: exit 0 for all focused commands on 2026-06-08.

## PAC-6 Verification

Completed iOS hierarchy cleanup:

- Moved Retry tests from `Tests/Engine/Transport/Clients` to
  `Tests/Engine/Transport/Retry`.
- Moved WebSocket client/auth tests from `Tests/Engine/Transport/Clients` to
  `Tests/Engine/Transport/WebSocket`.
- Moved Chat tests to the production-owner roots:
  `Coordinators`, `Messaging`, and `ViewModel`.
- Expanded `SourceGuardTests+Budgets` to guard the production Retry source
  root and the mirrored Retry/WebSocket/Chat test roots.
- Updated iOS architecture/development docs, the HRA Swift near-budget watch
  rows, and HRA/PCC inventory rows for the moved/new tracked paths.

Focused proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants ios_transport_and_chat_tests_mirror_production_owners -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants post_hra_adversarial_hardening_scorecard_stays_formalized -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants tracked_files_have_rearchitecture_inventory_rows -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants ios_hra8_ownership_map_covers_every_source_and_test_swift_file -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants primitive_code_cleanup_inventory_covers_tracked_files -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants inventory_and_provenance_have_no_open_or_external_closeout_state -- --nocapture
cd packages/ios-app && xcodegen generate
xcodebuild test -project TronMobile.xcodeproj -scheme 'Tron Beta' -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -quiet
xcodebuild test -project TronMobile.xcodeproj -scheme 'Tron Beta' -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/ConnectionErrorClassifierTests -only-testing:TronMobileTests/ConnectionManagerTests -only-testing:TronMobileTests/ConnectionToastPolicyTests -only-testing:TronMobileTests/NetworkDiagnosticsFormatterTests -only-testing:TronMobileTests/ReconnectProbePolicyTests -only-testing:TronMobileTests/EngineClientErrorTests -only-testing:TronMobileTests/ConnectionStateTests -only-testing:TronMobileTests/EngineStreamScopeTests -only-testing:TronMobileTests/ModelInfoTests -only-testing:TronMobileTests/WebSocketAuthTests -only-testing:TronMobileTests/MessagingCoordinatorTests -only-testing:TronMobileTests/StreamingManagerTests -only-testing:TronMobileTests/ChatViewModelEventRoutingTests -quiet
```

Result: exit 0 for all focused commands on 2026-06-08.

## PAC-5 Verification

Completed Mac guard parity:

- Added `packages/mac-app/Tests/Infrastructure/Guards/MacSourceGuardTests.swift`.
- Guard coverage includes required roots, banned roots, helper-resource layout,
  staged-binary policy, `bundle-agent --clean`, and Mac Swift files at or above
  590 LOC.
- `bundle-agent.sh --clean` now removes only ignored staged helper binaries:
  `tron` and `tron-program-worker` in both helper bundles.
- Clean mode preserves tracked helper `Info.plist` files, LaunchAgent plists,
  helper icons, and the shared `AppIcon.icns`.

Focused proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants mac_source_guards_cover_wrapper_contracts -- --nocapture
bash -n packages/mac-app/scripts/bundle-agent.sh
cd packages/mac-app && xcodegen generate
TRON_MAC_TEST_HOST=1 xcodebuild test -project TronMac.xcodeproj -scheme TronMac -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:TronMacTests/MacSourceGuardTests CODE_SIGN_IDENTITY='-' CODE_SIGN_STYLE=Manual -quiet
```

Result: exit 0 for all focused commands on 2026-06-08.

## PAC-4 Verification

Completed Mac ownership split:

- `LiveLaunchAgentManager` moved from `Server/Health/ServerPing.swift` to
  `Server/LaunchAgent/LiveLaunchAgentManager.swift`.
- `ProcessResult` and `Subprocess` moved to
  `Support/Foundation/Subprocess.swift`.
- Live launch-agent and install-runner tests moved from the fake-manager test
  file to `Tests/Server/LaunchAgent/LiveLaunchAgentManagerTests.swift`.
- `ServerPing.swift` now retains only `ServerPingResult`, `ServerPing`, and
  one-shot WebSocket status capture behavior.

Focused proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants mac_launch_agent_and_subprocess_have_physical_owners -- --nocapture
cd packages/mac-app && xcodegen generate
TRON_MAC_TEST_HOST=1 xcodebuild test -project TronMac.xcodeproj -scheme TronMac -destination 'platform=macOS,arch=arm64' -configuration Debug -only-testing:TronMacTests/ServerPingDecodeTests -only-testing:TronMacTests/ServerPingResultTests -only-testing:TronMacTests/ServerPingLiveTests -only-testing:TronMacTests/LiveLaunchAgentManagerTests -only-testing:TronMacTests/InstallLaunchAgentRunnerTests -only-testing:TronMacTests/MockLaunchAgentManagerTests CODE_SIGN_IDENTITY='-' CODE_SIGN_STYLE=Manual -quiet
```

Result: exit 0 for all focused commands on 2026-06-08.

## PAC-3 Verification

Completed runtime/docs parity repair:

- README startup registration now lists only `system`, `capability`, `blob`,
  `message`, `settings`, `auth`, `agent`, `logs`, `session`, and
  model-provider modules.
- README no longer claims a registered public `context` startup domain.
- README database inventory includes `engine_catalog_changes`,
  `engine_catalog_workers`, and `engine_catalog_functions`.

Focused proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants startup_domains_and_database_inventory_match_runtime_truth -- --nocapture
```

Result: exit 0, 1 passed.

```bash
cargo test --manifest-path packages/agent/Cargo.toml fresh_schema_contains_only_primitive_tables -- --nocapture
```

Result: exit 0, 1 passed.

## PAC-2 Verification

Completed source-truth path repair:

- README settings schema path is now
  `packages/agent/src/domains/settings/profile/types/`.
- README authentication schema path is now
  `packages/agent/src/domains/auth/credentials/types.rs`.
- README Event System points to
  `packages/agent/src/shared/protocol/events/`.
- README Install Directory points to
  `packages/agent/src/shared/foundation/paths/`.
- AGENTS README-maintenance rows use the current settings, auth, event, and
  path-helper source roots.
- AGENTS no longer names the deleted `packages/agent/src/domains/tools/`
  source-truth path.

Focused proof:

```bash
rg -n "settings/implementation|provider_credentials|shared/protocol/events\\.rs|shared/foundation/paths\\.rs|settings/types/|domains/tools" README.md AGENTS.md packages/agent/docs/post-aha-adversarial-closeout-scorecard.md packages/agent/docs/post-aha-adversarial-closeout-evidence-manifest.md packages/agent/tests/post_aha_adversarial_closeout
```

Result: exit 0 with hits only in
`packages/agent/tests/post_aha_adversarial_closeout/audit_findings.rs`, where
the stale paths are banned regression needles.

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants documented_source_truth_paths_exist_or_use_supported_globs -- --nocapture
```

Result: exit 0, 1 passed.

## PAC-1 Verification

Completed Mac generated-project policy repair:

- `.github/workflows/ci.yml` and `.github/workflows/release-mac.yml` no longer
  diff `packages/mac-app/TronMac.xcodeproj`.
- Both Mac workflows run `xcodegen generate`, verify
  `packages/mac-app/TronMac.xcodeproj` exists, and verify it is ignored with
  `git check-ignore`.
- CI still builds/tests from `TronMac.xcodeproj`; release-mac archives from the
  generated project.
- iOS workflows still run `git diff --exit-code
  packages/ios-app/TronMobile.xcodeproj`.
- AHA's older Xcode policy gate/docs now enforce the split policy rather than
  preserving the obsolete tracked-Mac project rule.

Focused proof:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_aha_adversarial_closeout_invariants mac_generated_project_policy_is_truthful -- --nocapture
```

Result: exit 0, 1 passed.

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants xcodegen_workflows_match_ios_tracked_and_mac_untracked_policy -- --nocapture
```

Result: exit 0, 1 passed.

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test post_hra_adversarial_hardening_invariants post_hra_adversarial_hardening_scorecard_stays_formalized -- --nocapture
```

Result: exit 0, 1 passed.

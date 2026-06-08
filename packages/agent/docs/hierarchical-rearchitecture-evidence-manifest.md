# Hierarchical Rearchitecture Evidence Manifest

Current score: **94/100**

Status: **running**

Branch: `codex/primitive-engine-teardown`

Plan: `TRON_REARCHITECTURE_PLAN.md` from the operator Downloads directory.

## Evidence Rows

| ID | Status | Evidence | Verification | Open loops | Commit |
|----|--------|----------|--------------|------------|--------|
| HRA-0 | passed_after_fix | Created the scorecard, evidence manifest, human inventory, generated TSV inventory, generated move map, Rust invariant target, README living-doc links, and `scripts/tron.d/quality.sh` CI hook. The invariant target intentionally fails against the current tree on loose Rust root files, flat engine root modules, broad iOS source buckets, non-mirrored iOS test buckets, and over-budget files without decomposition rows. | Red output captured below. | Red gates are expected until HRA-2 through HRA-13 move the tree and HRA-1 records final budgets. | `f14f7b60c` |
| HRA-1 | passed_after_fix | Replaced HRA-0 placeholder TSVs with a live tracked-file target map; recorded counts, extension counts, package counts, loose root files, overfull folders, one-file folders, generic bucket folders, same-name file/folder pairs, over-budget files, docs/scripts old-path claims, and retained folder owners. No code files were moved in this row. | Focused HRA invariant rerun improved from 2 passed/5 failed to 3 passed/4 failed: formalization, inventory coverage, and large-file budget gates pass; root Rust, engine root, iOS source bucket, and iOS test mirror gates remain red for implementation rows. | Pending move/split implementation rows remain HRA-2 through HRA-14; docs closeout remains HRA-15. | `58be3f8df` |
| HRA-2 | passed_after_fix | Moved `main_cli.rs`, `main_runtime.rs`, and `main_tests.rs` under `app/cli` and `app/bootstrap`; moved app config/disk/server/health/metrics/onboarding/shutdown under bootstrap/health/lifecycle; moved transport auth/contracts/engine/engine_ws/setup under http/engine/runtime; collapsed shared root into foundation/protocol/server/storage/observability; removed old path modules instead of re-exporting them. | `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` passed; `cargo test --manifest-path packages/agent/Cargo.toml --lib app::bootstrap -- --quiet` passed 80 tests; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet` passed 27 tests; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet` passed 16 tests; `cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet` passed 13 tests; HRA invariant target is expected partial red with Rust source-root and HRA-2 shape gates passing. | iOS source/test gates remain red for HRA-9 through HRA-13. | `67b8a5aa6` |
| HRA-3 | passed_after_fix | Moved flat engine root modules into `kernel`, `catalog`, `invocation`, and `runtime`; collapsed `host.rs` plus `host/` into `invocation/host`; split the over-budget kernel type file into `kernel/types/{catalog,function,trigger,worker}.rs`; moved primitive `resource` and `ui` files to folder `mod.rs` owners so no engine same-name file/folder pairs remain. | Command batch passed except the expected partial-red HRA target: Rust engine gates pass and only iOS source/test gates fail. Full command outcomes recorded in HRA-3/HRA-4 verification below. | Runtime/test decomposition closed in HRA-7; later Rust loops are only broad final verification. | `ff4640ce8` |
| HRA-4 | passed_after_fix | Moved grants, leases, and compensation under `authority`; moved ledger, queue, resources, state, and streams under `durability`; kept SQLite codecs under their owning store folders; collapsed resource store into `durability/resources/store/mod.rs`; regenerated HRA and primitive cleanup inventories. | Command batch passed except the expected partial-red HRA target: authority/durability compile and engine tests pass. Full command outcomes recorded in HRA-3/HRA-4 verification below. | Authority/durability store modules remain cohesive but over 900 LOC with explicit temporary budget rows; no compatibility modules preserve old paths. | `ff4640ce8` |
| HRA-5 | passed_after_fix | Added expanded red domain hierarchy gates, then moved non-session domain helpers into owned vertical trees: registration helpers, agent prompt/loop/context, auth oauth/credentials, model routing/protocol, settings profile, capability operation modules, Kimi stream handler tests, and split over-budget HRA-5 domain tests. Deleted unused `resource_projection.rs` instead of preserving a dead module. | Focused checks passed for compaction engine, stream processor, auth storage, and Kimi stream handler; final HRA target rerun passed all Rust/HRA-5 gates and remains partial red only on iOS source/test gates. | Session/event-store closure moved to HRA-6; Rust test/doc budget cleanup moved to HRA-7. | `f8c8f356c` |
| HRA-6 | passed_after_fix | Added red session/event-store hierarchy gates, then moved session lifecycle/query/reconstruction into owner folders, moved event-store envelope/factory/reconstruction/store/session repository modules to folder-backed owners, removed session event-store same-name file/folder pairs, and split SQLite event repository tests by behavior. | Session domain tests passed; final HRA target rerun passed all Rust/HRA-6 gates and remains partial red only on iOS source/test gates. | Rust test/doc budget cleanup moved to HRA-7. | `18268fc26` |
| HRA-7 | passed_after_fix | Added red Rust test/progressive-doc gates, then mirrored engine tests to subsystem folders, split root static integration targets into folder-backed modules, decomposed over-budget Rust stores/runtime helpers, updated progressive docs and README, and regenerated inventories. | Engine tests passed; teardown, cleanup, and DB guards passed; final HRA target rerun passed all Rust/HRA-7 gates and remains partial red only on iOS source/test gates. | iOS hierarchy closure is owned by HRA-9 through HRA-13. | `b846c6e4e` |
| HRA-8 | passed_after_fix | Added HRA SourceGuard red hierarchy checks, generated the iOS source/test Swift move map, recorded the XcodeGen/share-extension project map, added HRA artifact inventory rows, and added a Rust map-coverage invariant. | XcodeGen exited 0 with no generated project drift; focused SourceGuard red proof compiled and failed only the two new HRA hierarchy tests; HRA invariant target now has the new iOS move-map guard passing and later HRA-13 turns all iOS map rows green. | HRA-14/HRA-15/HRA-16 remain. | `c21cdc6f8` |
| HRA-9 | passed_after_fix | Moved Engine `Network`, `Database`, `EventStore`, DTO, protocol, repository, and event core/type buckets into `Transport`, `Protocol`, `Events`, `Persistence`, and `Models` owners. Split `EngineConnection` into focused WebSocket request, receive, reconnect, frame, and type units without old-path shims. | XcodeGen passed; SourceGuard expected-red run passed the new HRA-9 Engine hierarchy guard and failed only future source/test hierarchy gates; focused Engine transport/protocol/client/persistence test batch passed 275 tests. | Closed; iOS test hierarchy is complete in HRA-13. | `d54995e64` |
| HRA-10 | passed_after_fix | Moved Session `ViewModels`, `Activity`, `Features`, `Messages`, `Reconstruction`, and `Tokens` into chat workflow, attachments, parsing, and timeline owners. Split `CapabilityInvocationDisplayModel` presentation helpers and placed `UnifiedEventTransformer` under `Session/Timeline/Reconstruction` because it projects stored events into chat timeline state. | XcodeGen passed; SourceGuard expected-red run passed the new HRA-10 Session hierarchy guard and failed only future UI/Support/test hierarchy gates; focused Session/view-model/reconstruction test batch passed 169 tests. | Closed; iOS test hierarchy is complete in HRA-13. | `9e0e05a00` |
| HRA-11 | passed_after_fix | Replaced `UI/Views` with feature-owned UI roots for chat, settings, onboarding, runtime surfaces, capabilities, components, system sheets, and theme. Split `GeneratedRuntimeSurfaceView` support types and `SettingsView` footer support so no iOS production UI file remains over the HRA line budget. | XcodeGen passed; SourceGuard expected-red run passed the new HRA-11 UI hierarchy guard and failed only Support/test hierarchy future gates; focused UI batch passed after updating source-reading tests to the new Settings paths; Rust teardown/cleanup invariants passed and HRA static target is expected partial red only on HRA-12/HRA-13 gates. | Closed; iOS test hierarchy is complete in HRA-13. | `b8c1c7c02` |
| HRA-12 | passed_after_fix | Moved App entry points under `App/Lifecycle`; moved dependency assembly to `Support/Composition`; collapsed diagnostics/storage service buckets; moved utilities, extensions, infrastructure, observability, and settings support files into diagnostics, feedback, foundation, pairing, share, and storage owners without compatibility shims. | XcodeGen passed; SourceGuard expected-red run passed the new HRA-12 Support hierarchy guard and failed only the HRA-13 test mirror gate; focused Support/App batch passed after fixing a stale cleanup terminology comment and retired Mac-path assertion. | Closed; iOS test hierarchy and SourceGuard decomposition are complete in HRA-13. | `d76384d2d` |
| HRA-13 | passed_after_fix | Moved 192 pre-existing iOS tests from old technical buckets into mirrored `Engine`, `Session`, `UI`, `Support`, and `Infrastructure` owners; split SourceGuard into same-suite guard extensions; split the large unified event transformer test into focused reconstruction suites; regenerated XcodeGen. | SourceGuard red proof failed on split self-scan and stale old test paths, then passed 34 tests after fixes. The moved-test batch red proof failed only stale capability UI source paths, then the rerun exited 0 with `** TEST SUCCEEDED **` and 124 Swift Testing cases in 9 suites passed. Rust formatting, primitive teardown, cleanup, and HRA static gates pass. | HRA-14/HRA-15/HRA-16 remain. | pending |
| HRA-14 | pending | Not started. | pending | Audit Mac hierarchy and move justified drift. | pending |
| HRA-15 | pending | Not started. | pending | Close docs/scripts/README old path references. | pending |
| HRA-16 | pending | Not started. | pending | Final verification, adversarial review, ledger, and closeout. | pending |

## HRA-0 Red Static Gate

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected red gate.

Summary:

```text
running 7 tests
test hierarchical_rearchitecture_scorecard_stays_formalized ... ok
test tracked_files_have_rearchitecture_inventory_rows ... ok
test ios_sources_do_not_use_broad_views_network_database_buckets ... FAILED
test ios_tests_mirror_source_boundaries ... FAILED
test rust_engine_root_has_no_unowned_flat_modules ... FAILED
test rust_source_root_has_only_allowed_entry_files ... FAILED
test large_files_have_decomposition_budget_rows ... FAILED

test result: FAILED. 2 passed; 5 failed
```

Failure inventory:

- `rust_source_root_has_only_allowed_entry_files`: `packages/agent/src/main_tests.rs`,
  `packages/agent/src/main_cli.rs`, and `packages/agent/src/main_runtime.rs`
  remain loose root files.
- `rust_engine_root_has_no_unowned_flat_modules`: flat engine root modules remain
  for compensation, ledger, policy, grants, types, host, registry, protocol,
  triggers, streams, discovery, leases, queue, schema, state, ids, errors,
  invocation, external, and capabilities.
- `ios_sources_do_not_use_broad_views_network_database_buckets`:
  `Sources/UI/Views`, `Sources/Engine/Network`, `Sources/Engine/Database`,
  `Sources/Engine/EventStore`, `Sources/Session/ViewModels/Managers`,
  `Sources/Session/ViewModels/Utilities`, `Sources/Support/Utilities`, and
  `Sources/Support/Extensions` remain.
- `ios_tests_mirror_source_boundaries`: `Tests/Engine`, `Tests/Session`, and
  `Tests/UI` are missing while old test buckets remain under `Core`,
  `Extensions`, `Models`, `Navigation`, `Observability`, `Onboarding`,
  `Repositories`, `Services`, `Theme`, `Utilities`, `ViewModels`, and `Views`.
- `large_files_have_decomposition_budget_rows`: 24 Rust/Swift files currently
  exceed HRA line budgets without explicit HRA-1 budget rows.

## HRA-1 Inventory Verification

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected partial red gate.

Summary:

```text
running 7 tests
test hierarchical_rearchitecture_scorecard_stays_formalized ... ok
test tracked_files_have_rearchitecture_inventory_rows ... ok
test large_files_have_decomposition_budget_rows ... ok
test ios_sources_do_not_use_broad_views_network_database_buckets ... FAILED
test ios_tests_mirror_source_boundaries ... FAILED
test rust_engine_root_has_no_unowned_flat_modules ... FAILED
test rust_source_root_has_only_allowed_entry_files ... FAILED

test result: FAILED. 3 passed; 4 failed
```

The remaining failures are not HRA-1 inventory defects. They are implementation
gates for HRA-2, HRA-3/HRA-4, HRA-9/HRA-12, and HRA-13.

## HRA-2 Rust Root Verification

Commands:

```bash
cargo check --manifest-path packages/agent/Cargo.toml --bin tron
cargo test --manifest-path packages/agent/Cargo.toml --lib app::bootstrap -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Results:

- `cargo check --bin tron`: passed.
- `app::bootstrap` unit slice: 80 passed.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.
- db path guard: 13 passed.
- HRA invariant target: expected partial red; Rust source root and HRA-2
  app/transport/shared shape gates pass, while engine and iOS gates remain red
  for later phases.

## HRA-3/HRA-4 Rust Engine Verification

Commands:

```bash
cargo check --manifest-path packages/agent/Cargo.toml --bin tron
cargo test --manifest-path packages/agent/Cargo.toml engine::tests:: --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Results:

- `cargo check --bin tron`: passed.
- `engine::tests::` lib slice: 175 passed, 2746 filtered.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.
- db path guard: 13 passed.
- `cargo fmt --all -- --check`: passed.
- `git diff --check --cached && git diff --check`: passed.
- HRA invariant target: expected partial red with 8 passed and 2 failed. Passing
  gates cover formalization, tracked inventory, Rust source root, HRA-2
  app/transport/shared roots, HRA-3/HRA-4 engine subsystem roots, engine
  same-name file/folder guard, and large-file budget rows. The two remaining
  failures are `ios_sources_do_not_use_broad_views_network_database_buckets`
  and `ios_tests_mirror_source_boundaries`, owned by HRA-9 through HRA-13.

## HRA-5 Red Domain Gates

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected red gate.

Summary:

```text
running 13 tests
test rust_non_session_domains_have_no_same_name_file_folder_pairs ... FAILED
test rust_capability_execute_operations_are_decomposed ... FAILED
test rust_settings_domain_keeps_worker_root_thin ... FAILED
test ios_sources_do_not_use_broad_views_network_database_buckets ... FAILED
test ios_tests_mirror_source_boundaries ... FAILED

test result: FAILED. 8 passed; 5 failed
```

New HRA-5 failures before implementation:

- `rust_non_session_domains_have_no_same_name_file_folder_pairs`
- `rust_capability_execute_operations_are_decomposed`
- `rust_settings_domain_keeps_worker_root_thin`

## HRA-5 Expanded Red Domain Gates

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected expanded red gate before implementation.

Summary:

```text
running 17 tests
10 passed; 7 failed
```

New or still-red HRA-5 failures before implementation:

- `rust_domain_root_has_only_owned_boundaries`
- `rust_agent_domain_uses_prompt_loop_context_owners`
- `rust_auth_domain_uses_oauth_and_credentials_owners`
- `rust_model_domain_uses_routing_and_protocol_owners`
- `rust_settings_domain_keeps_worker_root_thin`

The remaining two failures were existing iOS source/test hierarchy gates owned by
HRA-9 through HRA-13.

## HRA-5 Domain Verification

Commands run during implementation:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
cargo check --manifest-path packages/agent/Cargo.toml --bin tron
cargo test --manifest-path packages/agent/Cargo.toml domains:: --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml compaction_engine --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml stream_processor --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml auth::credentials::storage --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml kimi::stream_handler --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet
```

Results:

- `cargo fmt --all`: passed after split-boundary fixes.
- `cargo fmt --all -- --check`: passed.
- `cargo check --bin tron`: passed.
- `domains::` unit slice: 2,171 passed.
- `compaction_engine` unit slice: 51 passed.
- `stream_processor` unit slice: 33 passed.
- `auth::credentials::storage` unit slice: 77 passed.
- `kimi::stream_handler` unit slice: 17 passed.
- primitive engine teardown invariants: 27 passed after updating hardcoded old
  HRA-5 paths to their new owners.
- primitive code cleanup invariants: 16 passed after updating hardcoded old
  HRA-5 paths to their new owners.
- DB path guard: 13 passed.

Final HRA-5 static-gate rerun:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected partial red for later iOS phases.

Summary:

```text
running 17 tests
15 passed; 2 failed
```

Passing gates cover the HRA-5 Rust domain root, agent prompt/loop/context,
auth oauth/credentials, model routing/protocol, settings profile, capability
operation decomposition, non-session same-name pair, inventory, scorecard, and
large-file budget checks. The remaining failures are:

- `ios_sources_do_not_use_broad_views_network_database_buckets`
- `ios_tests_mirror_source_boundaries`

Checkpoint commit: `f8c8f356c`.

## HRA-6 Red Session/Event-Store Gates

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected red gate.

Summary:

```text
running 21 tests
15 passed; 6 failed
```

New HRA-6 failures before implementation:

- `rust_session_domain_uses_lifecycle_query_reconstruction_owners`
- `rust_session_event_store_has_no_same_name_file_folder_pairs`
- `rust_session_event_store_uses_owned_modules_without_path_attrs`
- `rust_session_event_repository_tests_are_behavior_split`

The remaining two failures are the existing iOS source/test hierarchy gates
owned by HRA-9 through HRA-13.

## HRA-6 Session/Event-Store Verification

Commands:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
cargo check --manifest-path packages/agent/Cargo.toml --bin tron
cargo test --manifest-path packages/agent/Cargo.toml domains::session --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
git diff --check --cached
git diff --check
```

Results:

- `cargo fmt --all`: passed.
- `cargo fmt --all -- --check`: passed.
- `cargo check --bin tron`: passed.
- `domains::session` unit slice: 412 passed.
- primitive engine teardown invariants: 27 passed after updating hardcoded old
  HRA-6 paths to their new owners.
- primitive code cleanup invariants: 16 passed after refreshing the current
  large-file exception table and updating the session operation guard for the
  lifecycle/query/reconstruction owner split.
- DB path guard: 13 passed.
- `git diff --check --cached` and `git diff --check`: passed.

Final HRA-6 static-gate rerun:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected partial red for later iOS phases.

Summary:

```text
running 21 tests
19 passed; 2 failed
```

Passing gates cover the HRA-6 Rust session lifecycle/query/reconstruction
owners, event-store folder-backed modules, event repository behavior-split tests,
inventory, scorecard, Rust source root, Rust app/transport/shared roots, Rust
engine subsystem roots, and HRA-5 domain hierarchy. The remaining failures are:

- `ios_sources_do_not_use_broad_views_network_database_buckets`
- `ios_tests_mirror_source_boundaries`

Checkpoint commit: `18268fc26`.

## HRA-7 Red Rust Test/Doc Gates

Command:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Result: exit 101, expected red gate before implementation.

Summary:

```text
running 24 tests
19 passed; 5 failed
```

New HRA-7 failures before implementation:

- `rust_engine_tests_are_mirrored_by_subsystem`
- `rust_hra7_has_no_remaining_overbudget_rust_files`
- `rust_progressive_docs_declare_dependency_and_test_ownership`

Existing failures remain the iOS hierarchy gates owned by HRA-9 through HRA-13.

## HRA-7 Rust Test/Doc Verification

Commands:

```bash
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
cargo check --manifest-path packages/agent/Cargo.toml --bin tron
cargo test --manifest-path packages/agent/Cargo.toml engine::tests:: --lib -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --quiet
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Results:

- `cargo fmt --all -- --check`: passed.
- `cargo check --bin tron`: passed.
- `engine::tests::` unit slice: 175 passed.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.
- DB path guard: 13 passed.
- HRA invariant target: expected partial red with 22 passed and 2 failed.

Final HRA-7 static-gate rerun:

```text
running 24 tests
22 passed; 2 failed
```

Passing gates cover mirrored Rust engine tests, Rust over-budget closure,
progressive module docs, root/static test decomposition, inventory coverage,
scorecard formalization, Rust source/app/transport/shared roots, engine roots,
domain hierarchy, session/event-store hierarchy, and large-file budget rows. The
remaining failures are:

- `ios_sources_do_not_use_broad_views_network_database_buckets`
- `ios_tests_mirror_source_boundaries`

Checkpoint commit: `b846c6e4e`.

## HRA-8 iOS Inventory, SourceGuard, And Project Map Verification

Commands:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture
```

Results:

- `xcodegen generate`: passed; no `TronMobile.xcodeproj` drift.
- SourceGuard focused target: exit 65, expected red proof. The target compiled,
  ran 30 Swift Testing cases, passed 28, and failed only:
  - `SourceGuardTests.testIOSSourcesUseHRAFeatureOwnedHierarchy`
  - `SourceGuardTests.testIOSTestsMirrorHRASourceBoundaries`
- SourceGuard xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_02-07-15--0700.xcresult`
- First `cargo fmt --all -- --check`: failed only because the new Rust
  move-map guard needed rustfmt wrapping; `cargo fmt --all` was run.
- HRA invariant target before final doc staging: expected partial red with 23
  passed and 2 failed. The new
  `ios_hra8_move_map_covers_every_source_and_test_swift_file` guard passed.

Final HRA-8 static-gate rerun:

```text
running 25 tests
23 passed; 2 failed
```

Remaining failures are the intended HRA-9 through HRA-13 implementation gates:

- `ios_sources_do_not_use_broad_views_network_database_buckets`
- `ios_tests_mirror_source_boundaries`

Checkpoint commit: `c21cdc6f8`.

## HRA-9 iOS Engine Hierarchy Verification

Commands:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/EngineTransportHelpersTests \
  -only-testing:TronMobileTests/EngineTransportConnectionGuardTests \
  -only-testing:TronMobileTests/EngineConnectionReconnectTests \
  -only-testing:TronMobileTests/EngineClientObservationTests \
  -only-testing:TronMobileTests/AgentClientTests \
  -only-testing:TronMobileTests/AuthClientTests \
  -only-testing:TronMobileTests/BlobClientTests \
  -only-testing:TronMobileTests/EventSyncClientTests \
  -only-testing:TronMobileTests/MiscClientTests \
  -only-testing:TronMobileTests/ModelClientTests \
  -only-testing:TronMobileTests/SessionClientTests \
  -only-testing:TronMobileTests/SettingsClientTests \
  -only-testing:TronMobileTests/CapabilitySchemaFormTests \
  -only-testing:TronMobileTests/GeneratedUIDTOTests
```

The focused Engine command also included the protocol DTO, default repository,
database, event-store sync, deep-link, diagnostics, retry, interaction-policy,
and WebSocket-auth test classes touched by the HRA-9 moves.

Results before final Rust static rerun:

- `xcodegen generate`: passed.
- SourceGuard focused target: exit 65, expected partial red. It ran 31 Swift
  Testing cases, passed 29, and failed only:
  - `SourceGuardTests.testIOSSourcesUseHRAFeatureOwnedHierarchy`
  - `SourceGuardTests.testIOSTestsMirrorHRASourceBoundaries`
- The new `SourceGuardTests.testIOSEngineUsesHRATargetHierarchy` passed,
  proving `Engine/Transport`, `Engine/Protocol`, `Engine/Events`, and
  `Engine/Persistence` roots exist while old `Network`, `Database`,
  `EventStore`, DTO, protocol, repository, and event-core buckets are absent.
- SourceGuard xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_02-23-55--0700.xcresult`
- Focused Engine transport/protocol/client/persistence batch: exit 0, 275
  tests passed in 29 suites.
- Focused Engine xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_02-25-21--0700.xcresult`
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`:
  passed.
- HRA invariant target: exit 101, expected partial red with 24 passed and 2
  failed. The new `ios_engine_hra9_sources_use_target_boundaries` gate passed;
  the remaining source hierarchy failure lists only Session, Support, and
  UI buckets, and the remaining test hierarchy failure is owned by HRA-13.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.

Open loops after HRA-9:

- HRA-10 Session, HRA-11 UI, and HRA-12 App/Support source moves are closed by
  later checkpoints.
- HRA-13 later closes iOS test hierarchy mirroring and SourceGuard
  decomposition.

Checkpoint commit: `d54995e64`.

## HRA-10 iOS Session Hierarchy Verification

Commands:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/ChatViewModelEventDispatchTests \
  -only-testing:TronMobileTests/ChatViewModelMessagingTests \
  -only-testing:TronMobileTests/ChatViewModelReconstructionTests \
  -only-testing:TronMobileTests/ChatViewModelStateTests \
  -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerActionProjectionTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerReconstructionOrderTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerTests
```

The focused Session command also included the chat coordinators, streaming,
navigation, token, activity, message model, reconstruction, and parser tests
touched by the HRA-10 moves.

Results before final Rust static rerun:

- `xcodegen generate`: passed.
- SourceGuard focused target: exit 65, expected partial red. It ran 32 Swift
  Testing cases, passed 30, and failed only:
  - `SourceGuardTests.testIOSSourcesUseHRAFeatureOwnedHierarchy`
  - `SourceGuardTests.testIOSTestsMirrorHRASourceBoundaries`
- The new `SourceGuardTests.testIOSSessionUsesHRATargetHierarchy` passed,
  proving `Session/Attachments`, `Session/Chat`, `Session/Parsing`, and
  `Session/Timeline` roots exist while old `Activity`, `Features`, `Messages`,
  `Reconstruction`, `Tokens`, and `ViewModels` buckets are absent.
- SourceGuard xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_02-44-27--0700.xcresult`
- Focused Session/view-model/reconstruction batch: exit 0, 169 tests passed in
  9 suites.
- Focused Session xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_02-45-42--0700.xcresult`
- `UnifiedEventTransformer` is Session timeline-owned. Engine owns decoding,
  persistence, and event transport; the transformer reconstructs `ChatMessage`
  timeline state from stored events, so `Session/Timeline/Reconstruction` is
  the narrower owner.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`:
  passed.
- HRA invariant target: exit 101, expected partial red with 25 passed and 2
  failed. The new `ios_session_hra10_sources_use_target_boundaries` gate passed;
  the remaining source hierarchy failure lists only UI and Support buckets, and
  the remaining test hierarchy failure is owned by HRA-13.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.

Open loops after HRA-10:

- HRA-12 App/Support source moves are closed by the HRA-12 checkpoint.
- HRA-13 later closes iOS test hierarchy mirroring and SourceGuard
  decomposition.

## HRA-11 iOS UI Hierarchy Verification

Commands:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/InputBarKeyboardTraversalTests \
  -only-testing:TronMobileTests/GeneratedUIRendererTests \
  -only-testing:TronMobileTests/SettingsPageContainerTests \
  -only-testing:TronMobileTests/AgentSettingsPageLayoutTests \
  -only-testing:TronMobileTests/ServerSettingsPageTests \
  -only-testing:TronMobileTests/ProvidersSettingsPageTests \
  -only-testing:TronMobileTests/AgentContextSettingsPageTests \
  -only-testing:TronMobileTests/OnboardingStateTests \
  -only-testing:TronMobileTests/NewSessionFlowTests
```

Results:

- `xcodegen generate`: passed.
- HRA-11 moved UI files into `UI/Chat`, `UI/Settings`, `UI/Onboarding`,
  `UI/RuntimeSurfaces`, `UI/Capabilities`, `UI/Components`, `UI/System`, and
  retained `UI/Theme`.
- `GeneratedRuntimeSurfaceView.swift` split into a 576-line root view plus a
  242-line support file. `SettingsView.swift` split into a 698-line root view
  plus a 38-line footer support file.
- SourceGuard focused target: exit 65, expected partial red. It ran 33 Swift
  Testing cases, passed 31, and failed only:
  - `SourceGuardTests.testIOSSourcesUseHRAFeatureOwnedHierarchy`
  - `SourceGuardTests.testIOSTestsMirrorHRASourceBoundaries`
- The new `SourceGuardTests.testIOSUIUsesHRATargetHierarchy` passed, proving
  `UI/Views` is absent and the HRA-11 target roots plus split UI files exist
  under the HRA line budget.
- SourceGuard xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_03-12-52--0700.xcresult`
- First focused UI batch: exit 65 red proof. It found six stale source-reading
  test path assertions still pointing at old Settings/UI buckets; runtime UI
  renderer, input bar, onboarding, providers, server settings, and agent/context
  Swift Testing suites passed. The stale paths were updated to
  `Sources/UI/Settings/Pages` and `Sources/UI/Settings/Shell`.
- Focused UI rerun: exit 0, 16 XCTest cases and 68 Swift Testing cases passed.
- Focused UI xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_03-14-56--0700.xcresult`
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`:
  passed after applying formatter output to path-updated Rust tests.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.
- HRA invariant target: exit 101, expected partial red with 26 passed and 2
  failed. The new `ios_ui_hra11_sources_use_target_boundaries` gate passed; the
  remaining source hierarchy failure lists only `Support/Utilities` and
  `Support/Extensions`, and the remaining test hierarchy failure is owned by
  HRA-13.
- `git diff --check` and `git diff --cached --check`: passed.
- Stale live-path scan found no old `Sources/UI/Views` references outside
  explicit banned-root guards.

Open loops after HRA-11:

- HRA-12 App/Support source moves are closed by the HRA-12 checkpoint.
- HRA-13 later closes iOS test hierarchy mirroring and SourceGuard
  decomposition.

## HRA-12 iOS Support Verification

Commands:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/AppConstantsTests \
  -only-testing:TronMobileTests/AsyncSemaphoreTests \
  -only-testing:TronMobileTests/AppInitializerTests \
  -only-testing:TronMobileTests/DependencyContainerTests \
  -only-testing:TronMobileTests/ClientLogIngestionServiceTests \
  -only-testing:TronMobileTests/DiagnosticsBundleBuilderTests \
  -only-testing:TronMobileTests/DiagnosticsRedactorTests \
  -only-testing:TronMobileTests/ErrorHandlerTests \
  -only-testing:TronMobileTests/MetricKitDiagnosticsStoreTests \
  -only-testing:TronMobileTests/TronLoggerTests \
  -only-testing:TronMobileTests/FeedbackComposerTests \
  -only-testing:TronMobileTests/KeyboardObserverTests \
  -only-testing:TronMobileTests/ToastCenterTests \
  -only-testing:TronMobileTests/PairingPersistorTests \
  -only-testing:TronMobileTests/PairingProbeTests \
  -only-testing:TronMobileTests/PairingValidationTests \
  -only-testing:TronMobileTests/PairingURLParserTests \
  -only-testing:TronMobileTests/DraftStoreTests \
  -only-testing:TronMobileTests/InputHistoryStoreTests \
  -only-testing:TronMobileTests/PairedServerStoreTests \
  -only-testing:TronMobileTests/PairedServerTokenStoreTests \
  -only-testing:TronMobileTests/ContentLineParserTests \
  -only-testing:TronMobileTests/DateParserTests \
  -only-testing:TronMobileTests/DateParserCachingTests \
  -only-testing:TronMobileTests/DateParserThreadSafetyTests \
  -only-testing:TronMobileTests/DurationFormatterTests \
  -only-testing:TronMobileTests/FolderCreationTests \
  -only-testing:TronMobileTests/ModelNameFormatterTests \
  -only-testing:TronMobileTests/ModelNameFormatterThreadSafetyTests \
  -only-testing:TronMobileTests/TaskFormattingTests \
  -only-testing:TronMobileTests/TokenFormatterTests \
  -only-testing:TronMobileTests/VersionDisplayTests \
  -only-testing:TronMobileTests/CleanupGuardTests
```

Results:

- `xcodegen generate`: passed.
- HRA-12 moved `AppDelegate.swift` and `TronMobileApp.swift` under
  `App/Lifecycle`; moved dependency assembly under `Support/Composition`;
  collapsed diagnostics and storage service folders; moved support utilities
  and Swift extensions into `Support/Foundation/{Concurrency,Formatting,Media,
  Parsing,SwiftUI,Validation}`; moved paired-server settings storage under
  `Support/Pairing`; retained share-extension data under `Support/Share`.
- SourceGuard focused target: exit 65, expected partial red. It ran 34 Swift
  Testing cases, passed 33, and failed only
  `SourceGuardTests.testIOSTestsMirrorHRASourceBoundaries`.
- The new `SourceGuardTests.testIOSSupportUsesHRATargetHierarchy` passed,
  proving the HRA-12 required App/Support roots exist and the banned broad
  support buckets plus old app/support files are absent.
- SourceGuard xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_03-22-31--0700.xcresult`
- First focused Support/App batch: exit 65 red proof. It found a stale
  `falls back` cleanup term in `ModelNameFormatter.swift` and a retired Mac
  source path in `CleanupGuardTests.displayHelpersAvoidLegacyFallbackTerminology`.
  The comment now uses deterministic heuristic wording, and the guard reads the
  current Mac support path.
- Focused Support/App rerun: exit 0, 207 tests in 21 suites passed.
- Focused Support/App xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_03-27-05--0700.xcresult`
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`:
  passed.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.
- HRA invariant target: exit 101, expected partial red with 28 passed and 1
  failed. The new `ios_support_hra12_sources_use_target_boundaries` gate passed;
  the only remaining failure is
  `hierarchical_rearchitecture::ios_and_budgets::ios_tests_mirror_source_boundaries`,
  owned by HRA-13.

Open loops after HRA-12:

- HRA-13 later closes iOS test hierarchy mirroring and SourceGuard
  decomposition.
- HRA-14 still owns the Mac wrapper hierarchy audit.
- HRA-15 still owns stale path claims in docs/scripts/README outside evidence
  history.

## HRA-13 iOS Test Hierarchy Verification

Commands:

```bash
cd packages/ios-app && xcodegen generate
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests
xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/EngineClientTests \
  -only-testing:TronMobileTests/EventDatabaseTests \
  -only-testing:TronMobileTests/EngineProtocolTypesTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerBasicTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerCoverageBatchTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerStateTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerCharacterizationTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerTokenMetadataTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerMapsAndCompactionTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerActionProjectionTests \
  -only-testing:TronMobileTests/UnifiedEventTransformerReconstructionOrderTests \
  -only-testing:TronMobileTests/ChatViewModelEventRoutingTests \
  -only-testing:TronMobileTests/CapabilityArgumentParserTests \
  -only-testing:TronMobileTests/TokenRecordTests \
  -only-testing:TronMobileTests/GeneratedUIRendererTests \
  -only-testing:TronMobileTests/SettingsPageContainerTests \
  -only-testing:TronMobileTests/AgentSettingsPageLayoutTests \
  -only-testing:TronMobileTests/InputBarKeyboardTraversalTests \
  -only-testing:TronMobileTests/OnboardingStateTests \
  -only-testing:TronMobileTests/CapabilityInvocationDetailViewTests \
  -only-testing:TronMobileTests/DependencyContainerTests \
  -only-testing:TronMobileTests/DiagnosticsBundleBuilderTests \
  -only-testing:TronMobileTests/AppConstantsTests \
  -only-testing:TronMobileTests/DateParserTests \
  -only-testing:TronMobileTests/PairingURLParserTests \
  -only-testing:TronMobileTests/DraftStoreTests \
  -only-testing:TronMobileTests/CleanupGuardTests \
  -only-testing:TronMobileTests/InfoPlistPrivacyTests
```

Results:

- `xcodegen generate`: passed after the test moves and split files; the tracked
  `TronMobile.xcodeproj` was regenerated from `project.yml`.
- HRA-13 moved all old iOS test buckets into `Tests/Engine`,
  `Tests/Session`, `Tests/UI`, `Tests/Support`, and
  `Tests/Infrastructure`. Old `Core`, `Extensions`, `Models`, `Navigation`,
  `Observability`, `Onboarding`, `Repositories`, `Services`, `Theme`,
  `Utilities`, `ViewModels`, and `Views` test roots are absent.
- `SourceGuardTests` was decomposed into same-suite extension files under
  `Tests/Infrastructure/Guards`, and `UnifiedEventTransformerTests` was split
  into focused Session timeline reconstruction suites. No iOS test source file
  remains over the 700-line HRA budget.
- First SourceGuard rerun: exit 65 red proof. It ran 34 tests and failed only:
  - `SourceGuardTests.testPrimitiveShellHasNoUserInteractionPausePlane`
  - `SourceGuardTests.testPrimitiveShellHasNoFixedProcessSessionActivityPlane`
  - `SourceGuardTests.testPromptTransportHasOneAttachmentPlane`
- The SourceGuard failures were stale split-file self-scan and old prompt
  transport test paths. After replacing them with split-aware guards and current
  `Tests/Engine/Transport/Clients` paths, the rerun exited 0 with 34 tests
  passed.
- SourceGuard green xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_03-46-35--0700.xcresult`
- First moved-test batch: exit 65 red proof. It failed only two stale
  `CapabilityInvocationDetailViewTests` source-path assertions still reading
  `Sources/UI/Views/Capabilities`; those assertions now read
  `Sources/UI/Capabilities` and `Sources/UI/Capabilities/Shared`.
- Moved-test batch rerun: exit 0, `** TEST SUCCEEDED **`; the Swift Testing
  subset reported 124 tests in 9 suites passed, and the selected XCTest suites
  also passed.
- Moved-test green xcresult:
  `/Users/<USER>/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.08_03-51-21--0700.xcresult`
- First primitive engine teardown invariant rerun after the test move: exit 101
  red proof. It exposed stale HRA-13 paths for `AgentClientTests`,
  `DefaultAgentRepositoryTests`, `EngineProtocolTypesTests`,
  `GeneratedUIDTOTests`, and `GeneratedUIRendererTests`, plus absence scans that
  needed to skip the new split SourceGuard guard files. After updating those
  paths and the guard-skip helper, the rerun passed 27 tests.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`:
  passed.
- primitive engine teardown invariants: 27 passed.
- primitive code cleanup invariants: 16 passed.
- HRA invariant target: 29 passed, 0 failed. The iOS test mirror,
  iOS move-map coverage, and large-file budget gates are now green.

Open loops after HRA-13:

- HRA-14 still owns the Mac wrapper hierarchy audit.
- HRA-15 still owns stale path claims in docs/scripts/README outside evidence
  history.
- HRA-16 still owns final adversarial review and closeout.

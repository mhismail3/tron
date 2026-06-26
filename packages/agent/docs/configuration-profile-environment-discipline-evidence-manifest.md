# Configuration / Profile / Environment Discipline Evidence Manifest

Branch: `codex/configuration-profile-environment-discipline-current`
Baseline: `c1d266e224f87fb57f18f85846f2c8931e038ec8`
Stale branch policy: `codex/configuration-profile-environment-discipline` and `codex/configuration-profile-environment-discipline-recovery` are quarry-only and were not merged, cherry-picked, or copied wholesale.

## Source Findings

| Evidence | Rows | Result |
| --- | --- | --- |
| Binding slice list | CPE-0 | `$CODEX_HOME/attachments/fdc4e780-354b-4da4-8fb5-57839c35bfee/pasted-text.txt` names Configuration / Profile / Environment Discipline as an original remaining meta-slice. |
| Lineage proof | CPE-0 | `git merge-base --is-ancestor` passed for DSEMD -> PPACD -> post-PPACD reconciliation -> PMBD -> PERF and for `c1d266e22` -> current branch. |
| Settings/profile audit | CPE-1,CPE-2,CPE-3,CPE-4,CPE-7 | Rust settings/profile docs, loader, store, seeder, and profile runtime were read before edits; existing tests already proved sparse writes, rollback, profile recovery, and cache reload. |
| Default drift finding | CPE-2,CPE-7 | `packages/agent/defaults/profiles/default/profile.toml` contained inert `settings.session.queueDrainMode`; it was removed and guarded by strict nested schema tests. |
| iOS fallback finding | CPE-6,CPE-7 | Swift `ServerSettings` used `try?` plus local defaults for server-owned fields; decoder now requires the fields iOS exposes and negative tests cover missing/mistyped payloads. |
| Mac sparse seed finding | CPE-4,CPE-5 | `ServerSettingsWriter` created missing overlays with v2 metadata and `inherits = ["normal"]`; it now creates the current v3 sparse overlay with no inherited defaults. |
| Slice 21A README drift finding | CPE-2,CPE-6,CPE-8,CPE-9 | The root README Key Configuration example documented `retry.maxRetries` as `1`, while `TronSettings::default()` and `packages/agent/defaults/profiles/default/profile.toml` use `3`; Slice 21A fixes the README and guards the documented settings catalog against source defaults. |

## Verification Matrix

| Command | Rows | Result |
| --- | --- | --- |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::settings --lib -- --nocapture` | CPE-2,CPE-3,CPE-7 | Passed: 129 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml shared::foundation::profile --lib -- --nocapture` | CPE-4 | Passed: 10 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture` | CPE-1,CPE-8,CPE-9 | Passed in closeout. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture` | CPE-2,CPE-6,CPE-8,CPE-9 | Slice 21A implementation-candidate run passed: 12 tests, including `readme_key_configuration_catalog_matches_settings_defaults` and `ios_user_editable_settings_have_decode_update_state_and_ui_coverage`. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture` | CPE-8 | Passed in closeout as affected predecessor/current-lineage guard. |
| `cd packages/ios-app && xcodegen generate` | CPE-6,CPE-8,CPE-10 | Passed in closeout. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TronMobileTests/ServerSettingsTests` | CPE-6,CPE-7,CPE-10 | Passed in closeout because Swift protocol/settings files changed. |
| `scripts/tron ci fmt check clippy test` | CPE-10 | Passed in closeout. |
| `scripts/personal-info-guard.sh` | CPE-10 | Passed in closeout. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | CPE-8,CPE-10 | Passed in closeout. |
| `git diff --check` | CPE-10 | Passed in closeout. |
| `git ls-files -ci --exclude-standard` | CPE-10 | Passed in closeout. |
| `git status --short --branch` | CPE-10 | Clean after commit. |

## Residual Risk

- Environment overrides still intentionally ignore invalid numeric/string values with a warning where the parser is range-checked; this preserves file/default settings instead of accepting unsafe env values.
- iOS exposes the current user-facing server settings subset. Server-only/internal profile settings are classified in the CPE inventory with ownership evidence instead of expanding the mobile UI into a raw configuration editor.

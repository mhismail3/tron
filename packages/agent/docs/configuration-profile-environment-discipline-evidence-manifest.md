# Configuration / Profile / Environment Discipline Evidence Manifest

Status: **closed**
Current score: **100/100**

Branch: `codex/configuration-profile-environment-discipline`
Base commit: `43379c475bd76caeca97bbbd15d479b7b85afcca`

Scorecard:
[`configuration-profile-environment-discipline-scorecard.md`](configuration-profile-environment-discipline-scorecard.md)

Inventory:
[`configuration-profile-environment-discipline-inventory.md`](configuration-profile-environment-discipline-inventory.md)
and
[`configuration-profile-environment-discipline-inventory.tsv`](configuration-profile-environment-discipline-inventory.tsv)

Invariant target:
[`../tests/configuration_profile_environment_discipline_invariants.rs`](../tests/configuration_profile_environment_discipline_invariants.rs)

## Source Inspection

- Confirmed branch `codex/configuration-profile-environment-discipline` and
  base commit `43379c475bd76caeca97bbbd15d479b7b85afcca` before source edits.
- Read root `AGENTS.md`, the original campaign plan attachment at
  `/Users/<USER>/.codex/attachments/fdc4e780-354b-4da4-8fb5-57839c35bfee/pasted-text.txt`,
  and relevant settings/profile module docs before source edits.
- Confirmed `@self-inspect` is referenced by project instructions but is not an
  available skill in this session; source inspection and direct `rg`/test
  evidence were used instead.
- Built `configuration-profile-environment-discipline-inventory.tsv` before
  source edits and recorded source-grounded CPE gaps there.

## Row Evidence

| Row | Status | Evidence |
| --- | --- | --- |
| CPE-0 | passed | Harness artifacts, CPE invariant target, README links, local gate, GitHub gate, and HRA ownership rows are present on the requested branch/base. |
| CPE-1 | passed | Inventory covers required Rust settings/profile files, load/write/reset paths, protocol/handlers, README, iOS parity files, env surfaces, static gates, and HRA ownership rows. |
| CPE-2 | passed | `packages/agent/defaults/profiles/default/profile.toml` no longer carries the stale session key, `bundled_default_profile_settings_match_rust_defaults` guards managed defaults, and reset/update paths remain sparse. |
| CPE-3 | passed | `SETTINGS_ENV_ALLOWLIST` is the canonical settings env override list, `apply_env_overrides_from` is transactional, and malformed numeric env overrides return `SettingsError::InvalidValue`. |
| CPE-4 | passed | Nested settings structs now reject unknown fields; focused tests cover unknown nested settings, wrong types, removed settings, malformed TOML, missing sparse files, and malformed env overrides. |
| CPE-5 | passed | Public settings DTO and iOS settings parity files were inspected; No iOS settings/protocol/UI files were touched because this slice changed private settings parsing/default discipline only. |
| CPE-6 | passed | README Settings examples now match retry defaults and the settings env allowlist; default profile drift is guarded by Rust tests. |
| CPE-7 | passed | `ProfileRuntime::effective_settings` maps env override failures to invalid-data settings errors and retains last-valid runtime semantics; `SettingsStore::operation_lock` source marker guards reset/update/reload sequencing. |
| CPE-8 | passed | Bundled default profile parsing is compared with `TronSettings::default()` and strict serde schema markers guard default drift. |
| CPE-9 | passed | Local and GitHub CPE gates are wired while predecessor targets remain listed; SACB inventory was repaired to include PRG and CPE artifact rows. |
| CPE-10 | passed | Required verification commands are recorded below, including failed attempts and corrections; final status is clean after staging and commit workflow. |

## Verification Log

Commands are recorded as passed only after their final run passes.

| Command | Result | Notes |
| --- | --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed | Final formatting gate completed with exit code 0. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed | Final compile check completed with exit code 0. |
| `cargo test --manifest-path packages/agent/Cargo.toml domains::settings --lib -- --nocapture` | passed | Final focused settings run passed: 127 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture` | passed | Earlier in-progress runs failed while artifacts were still open; final artifact/source state passed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture` | passed | Final PRG predecessor target passed: 8 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture` | passed | Final PMBD predecessor target passed: 7 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | passed | Final PPACD predecessor target passed: 5 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture` | passed | Final DISEMD predecessor target passed: 5 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | passed | Final ODA predecessor target passed: 11 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | passed | Initial run failed because SACB inventory missed five PRG artifact rows; repaired inventory/docs/test count and reran successfully: 17 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture` | passed | Final OPSTC predecessor target passed: 5 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | passed | Final primitive trace target passed: 8 passed, 0 failed. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | passed | Final integration target passed: 2 passed, 0 failed. |
| `scripts/tron ci fmt check clippy test` | passed | Initial closeout run failed in the PCC predecessor target; staged reruns then exposed HRA file-inventory and SACB marker-coverage gaps; final rerun completed with exit code 0 after all predecessor inventory corrections. |
| `scripts/personal-info-guard.sh` | passed | Personal-info guard completed with exit code 0. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | XcodeGen project drift check completed with no diff. |
| `cd packages/mac-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/mac-app/TronMac.xcodeproj` | passed | XcodeGen project drift check completed with no diff. |
| `git diff --check` | passed | Whitespace check completed with exit code 0. |
| `git ls-files -ci --exclude-standard` | passed | Ignored-file check produced no tracked ignored files. |
| `git status --short` | passed | Pre-stage status showed only expected CPE, SACB preservation, README, gate, and settings changes; final post-commit status is clean. |

## Failed Attempt Corrections

- Initial focused settings run failed because
  `load_rejects_wrong_type_settings` asserted serde would include the nested
  key name in its error text. The behavior was already fail-closed; the test now
  asserts rejection without coercion and the final settings run passed.
- Initial CPE invariant runs failed while the scorecard, inventory, and evidence
  artifacts were still open. Source-marker gaps were corrected by making the env
  parser's `Err(SettingsError::InvalidValue(...))` path and
  `SettingsStore::operation_lock` invariant marker explicit.
- Initial SACB predecessor run failed because closed PRG scorecard/evidence/
  inventory/test artifacts had security markers but no SACB inventory rows.
  Added those rows, updated the SACB row-count docs/test to 664 rows, and reran
  SACB successfully.
- Initial full `scripts/tron ci fmt check clippy test` closeout run failed in
  `primitive_code_cleanup_invariants`: the PCC inventory did not yet classify
  closed PRG artifact files, and a retained settings unknown-field test used a
  retired queue setting token. Added PRG/CPE PCC inventory rows and replaced the
  test key with a non-retired unknown setting name; the focused PCC target and
  final full CI rerun passed.
- The first staged full CI rerun failed in
  `hierarchical_rearchitecture_invariants` because the HRA file inventory did
  not yet include the newly tracked CPE artifacts. Added the matching CPE rows
  to `hierarchical-rearchitecture-file-inventory.tsv`; the focused HRA target
  and final full CI rerun passed.
- A subsequent staged full CI rerun failed in
  `security_authority_capability_boundaries_invariants` because three tracked
  CPE artifacts carried security/static-gate markers but lacked SACB boundary
  rows. Added those rows, updated SACB count references from 664 to 667, and
  reran the focused SACB target successfully before the final full CI pass.
- An incidental local row-count check using `python` failed because `python` is
  not installed in this shell; repeated the check with `awk` and confirmed the
  final 667 SACB inventory rows.

## iOS Test Rationale

No iOS settings/protocol/UI files were touched. The iOS 26.5 simulator is
available, but targeted simulator validation is not required because this slice
did not add, remove, or rename public settings fields and did not modify
`ServerSettings`, `ServerSettingsUpdate`, `SettingsState`, or settings UI pages.
The required XcodeGen drift check still runs for the iOS project.

## Residual Risk

No CPE-specific residual risk is accepted.

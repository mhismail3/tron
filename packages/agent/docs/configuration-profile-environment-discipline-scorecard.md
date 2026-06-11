# Configuration / Profile / Environment Discipline Scorecard

Status: **closed**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/configuration-profile-environment-discipline`
Base commit: `43379c475bd76caeca97bbbd15d479b7b85afcca`

Evidence:
[`configuration-profile-environment-discipline-evidence-manifest.md`](configuration-profile-environment-discipline-evidence-manifest.md)

Inventory:
[`configuration-profile-environment-discipline-inventory.md`](configuration-profile-environment-discipline-inventory.md)
and
[`configuration-profile-environment-discipline-inventory.tsv`](configuration-profile-environment-discipline-inventory.tsv)

Invariant target:
[`../tests/configuration_profile_environment_discipline_invariants.rs`](../tests/configuration_profile_environment_discipline_invariants.rs)

| ID | Row | Weight | Status | Evidence |
| --- | --- | ---: | --- | --- |
| CPE-0 | Harness, Baseline, and Scope Control | 5 | passed | Branch/base confirmed; CPE artifacts and invariant target were added on the requested branch from the requested base without deployment commands. |
| CPE-1 | Settings/Profile/Environment Inventory | 10 | passed | Inventory was created before source edits and covers Rust settings, profile load/write/reset, public DTOs, README, iOS parity, env usage, gates, and HRA ownership rows. |
| CPE-2 | Managed Defaults and Sparse User Overrides | 12 | passed | Managed default profile now matches Rust defaults; stale `settings.session.queueDrainMode` is removed; sparse user reset/update paths remain guarded. |
| CPE-3 | Environment Variable Precedence and Intentionality | 10 | passed | Settings env overrides are explicit, allowlisted, transactional, and fail closed on malformed numeric values. |
| CPE-4 | Malformed Config and Safe Failure Semantics | 10 | passed | Nested settings structs reject unknown fields; malformed TOML, wrong types, removed settings, missing sparse files, and malformed env overrides have focused tests. |
| CPE-5 | iOS Settings Parity and Reset Semantics | 12 | passed | Public settings DTO/iOS parity was inspected; no iOS settings/protocol/UI source files were touched because no public settings fields changed. |
| CPE-6 | README/Profile Examples/Generated Defaults Accuracy | 8 | passed | README Settings docs now match retry defaults and intentional env overrides; generated default profile drift is guarded by Rust tests. |
| CPE-7 | Runtime Load/Reset/Restart Semantics | 8 | passed | Profile runtime maps malformed env/settings loads to invalid-data failures and preserves the previous valid runtime snapshot; store operation locking remains guarded. |
| CPE-8 | Generated Default Profile and Drift Guards | 8 | passed | Bundled default profile settings are tested against `TronSettings::default()` and strict schema parsing. |
| CPE-9 | Cross-Slice Preservation and Static Gate Integration | 10 | passed | CPE target is wired into local and GitHub gates; predecessor gates remain listed and the SACB inventory now covers PRG artifacts. |
| CPE-10 | Evidence, Closeout, and Clean State | 7 | passed | Evidence manifest records the required commands, failed attempts and corrections, iOS no-touch rationale, and final clean-state workflow. |

Total weight: **100**

## Closed Changes

- Added strict unknown-field rejection to nested settings structs so retired
  profile keys fail safely instead of being silently ignored.
- Removed the stale managed default profile `settings.session.queueDrainMode`
  value and added a default-profile parity test against canonical Rust defaults.
- Made settings env overrides explicit, allowlisted, transactional, and
  fail-closed for malformed numeric values.
- Kept iOS settings untouched because the public settings DTO did not change;
  parity remains covered by source inspection and existing iOS parity tests.

## Residual Risk

No CPE-specific residual risk is accepted.

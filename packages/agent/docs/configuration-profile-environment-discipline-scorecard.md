# Configuration / Profile / Environment Discipline Scorecard

Status: **closed**

Current score: **100/100**

Passing threshold: **100/100**

This scorecard covers original primitive-engine hardening item 6 only:
configuration, profile defaults, sparse overrides, environment overrides, iOS
settings parity, malformed config safety, README/settings parity, and generated
default profile drift.

| ID | Row | Weight | Status | Evidence |
| --- | --- | ---: | --- | --- |
| CPE-0 | Harness, Baseline, Scope Control | 5 | passed | Branch/base verified at `43379c475bd76caeca97bbbd15d479b7b85afcca`; static gate added at `packages/agent/tests/configuration_profile_environment_discipline_invariants.rs`. |
| CPE-1 | Settings/Profile/Environment Inventory | 10 | passed | Inventory captured in `configuration-profile-environment-discipline-inventory.md` and TSV. |
| CPE-2 | Managed Defaults and Sparse User Overrides | 12 | passed | Default profile drift and sparse writer/reset semantics audited; stale session key removed from managed defaults. |
| CPE-3 | Environment Variable Precedence and Intentionality | 10 | passed | Env override allowlist and transactional fail-closed parser added in `profile/storage/loader.rs`. |
| CPE-4 | Malformed Config and Safe Failure Semantics | 10 | passed | Strict nested settings decode and malformed env tests added. |
| CPE-5 | iOS Settings Parity and Reset Semantics | 12 | passed | Public Rust DTO fields audited against Swift decode/update/state/UI surfaces. |
| CPE-6 | README/Profile Examples/Generated Defaults Accuracy | 8 | passed | README Settings section and default profile updated to match source. |
| CPE-7 | Runtime Load/Reset/Restart Semantics | 8 | passed | SettingsStore update/reset rollback semantics preserved and inventoried. |
| CPE-8 | Generated Default Profile and Drift Guards | 8 | passed | Bundled default profile schema test and CPE static guard cover default drift. |
| CPE-9 | Cross-Slice Preservation and Static Gate Integration | 10 | passed | CPE target wired into local quality gate, GitHub static gate, README, and HRA ownership rows. |
| CPE-10 | Evidence, Closeout, Clean State | 7 | passed | Evidence manifest records the required command suite and clean worktree proof. |

## Scope Boundary

No new user-facing settings, providers, protocol methods, scheduler/autostart
behavior, successor-agent behavior, or worker orchestration surfaces belong to
this slice. iOS source is audited for parity; source edits are required only if
server/public setting parity is actually broken.

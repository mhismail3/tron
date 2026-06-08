# Post-AHA Adversarial Closeout Scorecard

Current score: **60/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

Baseline commit: `7b51e202d57af3340379acc2482a561cf2649860`

Plan: `/Users/<USER>/Downloads/PLAN (2).md`, redacted from the operator
Downloads path used to seed this campaign.

## Operating Rules

- Each row starts with a red guard or explicit failing proof, then lands the
  architecture/docs/test fix, targeted verification, evidence update, and a
  checkpoint commit.
- No runtime wire/API compatibility layer is added. Closeout work hardens
  architecture, source ownership, docs, guards, CI parity, and provenance.
- Legacy aliases, fallback branches, stale source-truth paths, and hollow
  drift checks are not acceptable closeout states.
- Generated Mac XcodeGen output stays ignored and untracked; iOS XcodeGen
  output stays tracked and drift-checked.
- Every phase records honest residuals before commit. Open loops stay visible
  here and in the evidence manifest until closed.

## Required Artifacts

| Artifact | Status | Purpose |
|----------|--------|---------|
| `packages/agent/docs/post-aha-adversarial-closeout-scorecard.md` | active | Weighted PAC scorecard, open-loop ledger, and closeout state. |
| `packages/agent/docs/post-aha-adversarial-closeout-evidence-manifest.md` | active | Red/green proof, verification commands, commit hashes, and residual risk. |
| `packages/agent/tests/post_aha_adversarial_closeout_invariants.rs` | active | Integration target for post-AHA closeout static gates. |

## Scorecard

Total weight: **100**

| ID | Area | Weight | Status | Owner | Evidence | Open loops |
|----|------|--------|--------|-------|----------|------------|
| PAC-0 | Scorecard, evidence, README, and red-gate setup | 6 | passed_after_fix | docs/static gates | Added this scorecard, the evidence manifest, README living-doc links, and the intentionally red `post_aha_adversarial_closeout_invariants` target. | Later rows turn the red gates green. |
| PAC-1 | Mac generated-project CI policy | 10 | passed_after_fix | CI/project generation | Mac workflows now generate `TronMac.xcodeproj`, verify it is ignored, and build/test/archive from that generated project; iOS workflows keep tracked `TronMobile.xcodeproj` drift checks. The older AHA policy gate was revised to enforce this split policy instead of the superseded tracked-Mac rule. | Closed; focused Mac guard/source organization remains PAC-4/PAC-5. |
| PAC-2 | README/AGENTS source-truth path repair | 12 | passed_after_fix | docs/source truth | README and AGENTS now point to `settings/profile/types/`, `auth/credentials/`, `shared/protocol/events/`, and `shared/foundation/paths/`; the dead `domains/tools` maintenance path was removed. The PAC source-truth guard passes and stale paths remain only as regression needles. | Closed. |
| PAC-3 | Runtime/docs parity and database inventory | 10 | passed_after_fix | runtime/docs parity | README startup registration no longer lists the deleted public `context` domain, and the database table inventory includes the full engine catalog table set (`engine_catalog_changes`, `engine_catalog_workers`, `engine_catalog_functions`) alongside the booted runtime storage tables. PAC parity and migration schema tests pass. | Closed. |
| PAC-4 | Mac launch-agent/process ownership | 12 | passed_after_fix | Mac architecture | `LiveLaunchAgentManager` moved to `Server/LaunchAgent`, `Subprocess` moved to `Support/Foundation`, live launch-agent tests moved to `Tests/Server/LaunchAgent`, and `ServerPing.swift` now owns only ping/status capture behavior. PAC ownership and focused Mac launch-agent/ping tests pass. | Closed; PAC-5 owns broader Mac SourceGuard coverage. |
| PAC-5 | Mac guard parity | 10 | passed_after_fix | Mac guard parity | Added `MacSourceGuardTests` coverage for required roots, banned roots, helper-resource layout, staged-binary policy, `bundle-agent --clean`, and 590 LOC warning rows. `bundle-agent --clean` now removes only ignored staged binaries and preserves tracked helper plists, Info.plists, and icons. | Closed. |
| PAC-6 | iOS hierarchy and mirrored tests | 9 | pending | iOS hierarchy | Pending. | Expand dense-root guards and move Retry/WebSocket/Chat tests under production-owner folders. |
| PAC-7 | Rust docs and LOC split budgets | 10 | pending | Rust docs/budgets | Pending. | Expand top-level progressive docs and require concrete split plan rows at 890+ LOC. |
| PAC-8 | Local/GitHub CI parity | 8 | pending | local/CI parity | Pending. | Add PAC plus missing closeout targets to local `scripts/tron ci test` and GitHub static gates. |
| PAC-9 | Provenance, privacy, and residue policy | 7 | pending | provenance/privacy/residue | Pending. | Add AHA plan digest, broaden personal-info scans, and define allowed fallback/compatibility wording contexts. |
| PAC-10 | Final closeout verification | 6 | pending | final closeout | Pending. | Run full Rust CI, focused iOS/Mac checks, privacy guard, ignored-artifact audit, residue scans, and final adversarial audit. |

## Static Gates

The Rust integration target
`post_aha_adversarial_closeout_invariants` owns these checks:

- `post_aha_adversarial_closeout_scorecard_stays_formalized`
- `mac_generated_project_policy_is_truthful`
- `documented_source_truth_paths_exist_or_use_supported_globs`
- `startup_domains_and_database_inventory_match_runtime_truth`
- `mac_launch_agent_and_subprocess_have_physical_owners`
- `mac_source_guards_cover_wrapper_contracts`
- `ios_transport_and_chat_tests_mirror_production_owners`
- `rust_progressive_docs_and_loc_split_plans_are_current`
- `local_and_github_ci_run_the_same_static_closeout_targets`
- `aha_provenance_privacy_and_residue_policy_are_in_repo`

## Allowed fallback/compatibility wording contexts

Live implementation, workflows, source-local docs, and README architecture
claims should avoid fallback or compatibility wording because those terms hide
old paths and dual behavior. The allowed contexts are:

- historical evidence that names a prior failure or removed surface;
- provider protocol term usage where an upstream API field is literally named
  that way;
- external CLI behavior notes that describe third-party command variance,
  without adding a Tron runtime branch.

## Open Loops

- PAC-6 through PAC-10 remain open. The current red target is the executable
  punch list for those rows.

## Rust/Swift Split-Plan Watchlist

PAC-7 owns this section. Files at or above 890 LOC must have a current LOC row
with a concrete split plan before PAC-7 can close.

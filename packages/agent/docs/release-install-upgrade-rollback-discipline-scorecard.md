# Release / Install / Upgrade / Rollback Discipline Scorecard

Status: **closed**
Current score: **100/100**
Passing threshold: **100/100**

Scope: harden release, install, upgrade, rollback, dev takeover, and generated-project ownership without adding product features, public `/engine` surfaces, provider-visible tools, iOS settings, scheduler/autostart behavior, deploy automation, repo-managed skills, or production service-manager behavior outside the source-grounded release/install boundary.

| ID | Row | Weight | Status | Evidence |
|---|---|---:|---|---|
| RUR-0 | Harness, Baseline, and Scope Control | 5 | passed | Branch attached to `codex/release-install-upgrade-rollback-discipline` at `58c94586da6a01f1f7e3f23624ee523bd832ec86`; no production deploy command run. |
| RUR-1 | Release/Install/Runtime Ownership Inventory | 10 | passed | Inventory and TSV cover scripts, Mac wrapper, LaunchAgent, SMAppService, generated projects, runtime dirs, scorecards, and CI guards. |
| RUR-2 | Port 9847 Ownership and Conflict Discipline | 12 | passed_after_fix | `tron dev` and `tron dev --stop` now refuse unknown port owners and only signal verified `Tron-Dev.app` listeners. |
| RUR-3 | Mac App Wrapper, SMAppService, and LaunchAgent Semantics | 12 | passed_source_verified | Mac wrapper remains the production SMAppService owner; Debug companion and isolated install semantics are documented and guarded by existing Mac source/tests. |
| RUR-4 | CLI Setup/Dev/Manual Deploy Safety | 10 | passed_after_fix | Manual deploy/preflight distinguish known dev takeover from external listeners; no `tron deploy` alias or CI deploy path exists. |
| RUR-5 | Install, Uninstall, Restart, Update Finalization, and Rollback Paths | 12 | passed_after_fix | Contributor uninstall stops known Tron labels/state, preserves database/workspace/secrets by default, and restart/update finalization stay health-gated. |
| RUR-6 | Upgrade/Rollback State Safety for Profiles, DBs, Generated Projects, and Runtime Dirs | 10 | passed_source_verified | Runtime cleanup is scoped to `internal/run`; profiles/auth/database/workspace are preserved unless explicit reset flags are supplied. |
| RUR-7 | Generated Project and Package Drift | 8 | passed_source_verified | iOS `TronMobile.xcodeproj` is tracked and drift-checked; Mac `TronMac.xcodeproj` is generated/ignored and checked as generated state. |
| RUR-8 | Clean-Machine and Stale-Install Proof | 8 | passed | Static stale-install proof, personal-info guard, generated-project drift checks, and ignored-file guard passed without production LaunchAgent installation. |
| RUR-9 | Docs, README, Inventories, Static Guards, and CI Wiring | 8 | passed_after_fix | README, HRA rows, SACB/PCC inventories, local quality gate, GitHub static gate, and RUR invariant target are synchronized. |
| RUR-10 | Evidence, Adversarial Audit, Clean State, and Commit | 5 | passed | Evidence manifest records the required validation matrix, adversarial inventory fixes, and clean staged state before commit. |

Closeout rule satisfied: the evidence manifest records real passing results for the required command matrix, and no production deploy command was run.

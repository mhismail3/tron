# Release / Install / Upgrade / Rollback Discipline Evidence Manifest

Branch: `codex/release-install-upgrade-rollback-discipline-current`
Baseline: `0ed28e7fb309ff7db355e4c8cc2ad0062e3c699a`
Stale branch policy: `codex/release-install-upgrade-rollback-discipline` is quarry-only and was not merged, cherry-picked, or copied wholesale.

## Source Findings

| Evidence | Rows | Result |
| --- | --- | --- |
| Binding slice list | RIURD-0 | `$CODEX_HOME/attachments/fdc4e780-354b-4da4-8fb5-57839c35bfee/pasted-text.txt` names Release / Install / Upgrade / Rollback Discipline as an original remaining meta-slice. |
| Lineage proof | RIURD-0 | Worktree started detached at `0ed28e7fb309ff7db355e4c8cc2ad0062e3c699a`; `git merge-base --is-ancestor 0ed28e7fb HEAD` passed before editing. |
| Stale branch quarantine | RIURD-0 | Existing `codex/release-install-upgrade-rollback-discipline` branch is present at `b44a09629` in another worktree and remains quarry-only. |
| Port ownership audit | RIURD-2 | `scripts/tron.d/dev.sh` stops the dev takeover job and installed service before binding port 9847, then restores the installed helper through the health-gated wrapper path. |
| Manual deploy audit | RIURD-2,RIURD-3,RIURD-5 | `scripts/tron.d/manual-deploy.sh` refuses active dev listeners and now treats service-loaded-but-unhealthy as failed deploy, with health-gated rollback and no deployed-commit advancement before health. |
| Rollback audit | RIURD-5 | `scripts/tron-lib.d/service.sh::cmd_rollback` now requires `service_is_running && wait_for_service_health 12` before recording `rolled_back` success. |
| Mac wrapper audit | RIURD-4,RIURD-6 | `TronPaths`, `MacRuntimeVariant`, `LiveLaunchAgentManager`, `MacAppStartupMaintenance`, `MacCommandModeServerStarter`, `DevServerStopper`, and `TronUninstaller` prove installed Release ownership, Debug companion non-ownership, isolated port 9848, stale registration repair, health-gated version finalization, and data-preserving uninstall. |
| Generated project audit | RIURD-7 | iOS uses tracked `TronMobile.xcodeproj` with CI/release diff checks; Mac uses ignored `TronMac.xcodeproj` generated from `project.yml` with CI/release existence and ignore checks before build/archive. |
| Clean-machine setup audit | RIURD-4 | Shell setup/install creates only the intended `~/.tron` runtime/profile/workspace support paths, seeds `auth.json`, and does not create standalone settings JSON; Mac install validates `/Applications/Tron.app` and bundled helper/plist before SMAppService registration. |

## Verification Matrix

| Command | Rows | Result |
| --- | --- | --- |
| `bash -n scripts/tron scripts/tron-cli scripts/tron.d/dev.sh scripts/tron.d/manual-deploy.sh scripts/tron.d/quality.sh scripts/tron.d/workspace.sh scripts/tron-lib.sh scripts/tron-lib.d/service.sh scripts/tron-lib.d/logs.sh scripts/tron-lib.d/bundle.sh scripts/tron-lib.d/auth.sh` | RIURD-3,RIURD-5 | Passed after deploy/rollback shell edits. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture` | RIURD-1,RIURD-2,RIURD-3,RIURD-4,RIURD-5,RIURD-7,RIURD-8,RIURD-9 | Passed: 9 tests. Early harness failures were brittle source-shape assertions and were fixed before closeout; final run passed after the rollback port-free guard was added. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture` | RIURD-8 | Passed: 12 tests after updating the CSD exact inventory row count from 114 to 115 for the RIURD predecessor row. |
| `scripts/tron ci fmt check clippy test` | RIURD-8,RIURD-10 | First run failed at `concurrency_scheduling_discipline_invariants` because the RIURD predecessor row changed the exact CSD inventory count; after updating that guard, the full rerun passed fmt, check, clippy, static gates, lib tests, and integration tests. |
| `scripts/personal-info-guard.sh` | RIURD-10 | Passed: full scan reported no personal-info leaks in source. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | RIURD-7,RIURD-10 | Passed: generated `TronMobile.xcodeproj` had no tracked drift. |
| `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TronMobileTests/ServerSettingsTests` | RIURD-7,RIURD-10 | Passed: Swift Testing reported 8 `ServerSettingsTests` tests passed and `** TEST SUCCEEDED **`. |
| `cd packages/mac-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/mac-app/TronMac.xcodeproj` | RIURD-7,RIURD-10 | Passed: generated ignored `TronMac.xcodeproj` did not create tracked drift. |
| `git diff --check` | RIURD-10 | Passed. |
| `git ls-files -ci --exclude-standard` | RIURD-10 | Passed with no tracked ignored files listed. |
| `git status --short --branch` | RIURD-10 | Passed hygiene check: branch `codex/release-install-upgrade-rollback-discipline-current` has only intentional uncommitted RIURD changes and new RIURD artifacts. |

## Runtime Process Evidence

No development server, LaunchAgent, or production deploy command was started while producing this artifact. The only runtime-adjacent validation was the targeted iOS 26.5 Simulator test recorded above. Runtime validation, if needed later, must use `tron dev` only and must record `tron dev --stop` plus final `tron status --json`.

## Residual Risk

- Mac app-hosted tests depend on local Xcode/macOS state. CI builds and focused Mac tests cover the non-mutating wrapper logic; app-hosted ServiceManagement registration remains a local/manual validation path.
- Manual contributor deploy is retained for local workflows and can notarize opportunistically when credentials exist. Production distribution remains the GitHub Release DMG path; this slice did not add production deployment automation.

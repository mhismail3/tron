# Release / Install / Upgrade / Rollback Discipline Scorecard

Status: **complete**
Current score: **100/100**
Passing threshold: **100/100**

Branch: `codex/release-install-upgrade-rollback-discipline-current`
Baseline: `codex/configuration-profile-environment-discipline-current` at `0ed28e7fb309ff7db355e4c8cc2ad0062e3c699a` (`Harden configuration profile environment discipline`)
Lineage: DSEMD -> PPACD -> OPSAA reconciliation -> PMBD -> PERF -> CPE -> RIURD.

Stale branch quarantined as quarry-only: `codex/release-install-upgrade-rollback-discipline`. Later-looking iOS, DX, documentation/evidence, and self-sufficient runtime branches are not completion evidence for this current-lineage slice.

| Row | Name | Weight | Status | Closure |
| --- | --- | ---: | --- | --- |
| RIURD-0 | Baseline, lineage, and stale-branch quarantine | 5 | passed | Verified the worktree started at `0ed28e7fb`, created `codex/release-install-upgrade-rollback-discipline-current`, and recorded the stale release branch as quarry-only. |
| RIURD-1 | Whole release/install lifecycle inventory | 8 | passed | Added markdown and TSV inventories covering CLI commands, dev takeover, manual deploy, setup/install/uninstall/restart, Mac wrapper, SMAppService, port 9847, release workflows, generated projects, environment actions, docs, CI, tests, and predecessor inventory links. |
| RIURD-2 | Port 9847 and process ownership discipline | 12 | passed | Source proof covers `tron dev` booting out the installed service before binding 9847, manual deploy refusing active dev listeners, Mac SMAppService refusing external port/DB-lock owners, and Mac dev-stop signaling only verified `Tron-Dev.app` listeners. |
| RIURD-3 | Safe dev/manual deploy separation | 10 | passed | Static guards prove dev, local quality, Codex environment actions, and Mac wrapper sources do not call manual deploy or the removed `tron deploy` alias; manual deploy remains an explicit workspace command only. |
| RIURD-4 | Setup, install, uninstall, restart, and clean-machine bootstrap | 12 | passed | Source proof covers intended `~/.tron` directory creation, managed auth/config seeding, GUI-helper install skip, `/Applications/Tron.app` validation, health-gated start/restart, and uninstall preserving database/workspace by default. |
| RIURD-5 | Upgrade finalization and rollback semantics | 12 | passed | Fixed contributor deploy so deployed-commit and restart sentinel complete only after `/health`; unhealthy deploys fail closed, attempt a health-gated rollback, and record failed/rolled-back status. Manual rollback now exits nonzero unless the restored helper passes `/health`. Mac update finalization already records the app-version marker only after health. |
| RIURD-6 | Mac wrapper and SMAppService boundaries | 10 | passed | Existing Mac code and tests prove installed Release owns production `com.tron.server`, Debug companion is non-managing, isolated Debug uses port 9848 and `.tron-dev`, stale registrations are repaired by the installed app, and command-mode start/uninstall use wrapper-owned SMAppService paths. |
| RIURD-7 | Generated project and packaging drift discipline | 8 | passed | Preserved the tracked iOS/ignored Mac XcodeGen split: CI/release jobs regenerate iOS and diff the tracked project, regenerate Mac and verify `TronMac.xcodeproj` stays ignored before build/archive/DMG checks. |
| RIURD-8 | Docs, README, predecessor inventories, and CI wiring | 9 | passed | Added RIURD scorecard/evidence/inventory files, README living-doc and CLI/deployment updates, local/GitHub static gate wiring, Mac docs verification notes, and predecessor inventory rows. |
| RIURD-9 | Targeted static gates and verification harness | 8 | passed | Added `release_install_upgrade_rollback_discipline_invariants.rs` with scorecard, inventory, port/process, deploy/rollback, setup/uninstall, generated-project, no-hidden-deploy, and predecessor-wiring guards. |
| RIURD-10 | Broad closeout and clean handoff | 6 | passed | Focused RIURD invariant, shell syntax, predecessor gates, XcodeGen drift checks, iOS 26.5 simulator validation, full CI, personal-info guard, diff hygiene, ignored-file scan, and final status are recorded in the evidence manifest before commit. |

## Corrections Made

- `tron manual-deploy` no longer prints success or advances `deployed-commit` when the candidate helper starts but never passes `/health`.
- Contributor deploy now updates `restart-sentinel.json` out of `restarting` on script-controlled success, failure, and rollback.
- Manual rollback now reports success only after the restored helper passes `/health`; otherwise it writes a failed deployment result and exits nonzero.

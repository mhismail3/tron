# Release / Install / Upgrade / Rollback Discipline Inventory

This inventory maps the retained release, install, development takeover, update finalization, rollback, generated-project, and clean setup surfaces that can start or package the Tron server.

## Taxonomy

- `cli`: workspace and installed CLI dispatch/help surfaces.
- `dev_server`: `tron dev` foreground/background takeover and stop behavior.
- `manual_deploy`: contributor-only deployment, preflight, lock, sentinel, backup, and deploy-result paths.
- `setup_install`: first-time setup, contributor install, clean-machine seeding, and uninstall behavior.
- `service_manager`: shared launchd, health, status, start, stop, restart, and rollback helpers.
- `mac_wrapper`: SwiftUI wrapper, SMAppService, helper validation, command mode, update finalization, process probing, and uninstall.
- `update_rollback`: app-version finalization, stale registration repair, rollback, and failed-upgrade handling.
- `generated_project`: XcodeGen project sources, tracked/ignored project policy, and drift checks.
- `release_workflow`: GitHub release pipelines and packaging checks.
- `rust_startup`: Rust server path/port/startup/shutdown/database lock surfaces.
- `environment`: Codex local actions and environment variables that can start development tooling.
- `docs_ci`: README, docs, scorecard/evidence/inventory, local quality, and GitHub static gates.
- `predecessor_inventory`: predecessor/current-lineage artifacts touched to preserve discoverability.

## Canonical Rules

1. Production Mac registration is owned by `/Applications/Tron.app` through `SMAppService.agent(plistName:)`.
2. Port 9847 has one active owner at a time: installed production helper, contributor LaunchAgent, or explicit `tron dev` takeover. Isolated Debug install testing uses port 9848.
3. `tron dev` is a development takeover. It stops production ownership before binding 9847, uses `Tron-Dev.app`, and restores the installed helper only through the health-gated wrapper path.
4. `tron manual-deploy` is a contributor-only, explicit workspace command. No dev, quality, Codex action, or Mac wrapper path may call it implicitly.
5. Manual deploy and rollback success require `/health`, not just launchd loaded state.
6. Clean setup may create intended profile/workspace/internal support paths and managed auth/config seeds. Uninstall preserves database and workspace by default.
7. Mac app update finalization records `mac-app-version.json` only after the current bundled helper is loaded and healthy; active `tron dev` defers production restart/finalization.
8. iOS `TronMobile.xcodeproj` is tracked and must not drift after `xcodegen generate`. Mac `TronMac.xcodeproj` is intentionally ignored and regenerated before build/release.
9. Production releases are manual tag/workflow-driven DMG and TestFlight pipelines. This slice does not add automatic production deployment.

## Source Findings

- The required audit item `packages/mac-app/Project.swift` is not present in this checkout. The current Mac project source is `packages/mac-app/project.yml`.
- `scripts/tron.d/manual-deploy.sh` previously advanced success paths after a single/soft health check. RIURD changed it to fail closed unless `/health` passes and to keep `deployed-commit` on the last healthy helper until then.
- `scripts/tron-lib.d/service.sh::cmd_rollback` previously printed rollback success after launchd loaded state. RIURD changed it to require a healthy listener.
- The stale release branch exists but is not authoritative. This inventory uses current-lineage source only.

The machine-readable inventory is `release-install-upgrade-rollback-discipline-inventory.tsv`.

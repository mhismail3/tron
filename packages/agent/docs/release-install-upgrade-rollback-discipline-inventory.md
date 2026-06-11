# Release / Install / Upgrade / Rollback Discipline Inventory

Status: Complete
Machine-readable TSV: `packages/agent/docs/release-install-upgrade-rollback-discipline-inventory.tsv`

## Scope

This inventory covers the RUR slice's release/install/runtime ownership surfaces: workspace CLI, installed runtime CLI, contributor launchd setup, production Mac wrapper, SMAppService Login Item registration, LaunchAgent plist generation, dev takeover, manual deploy, setup, uninstall, restart, update finalization, rollback, generated Xcode projects, runtime state under `~/.tron`, existing closeout guards, and clean-machine/stale-install proof paths.

## Ownership Summary

- Production Mac install ownership is `Tron.app` at `/Applications/Tron.app`, with bundled helpers and LaunchAgents registered by `SMAppService`.
- Contributor shell install/manual-deploy/rollback ownership is workspace-only and writes under `~/.tron/internal/run` plus the user LaunchAgents path only for the legacy contributor service.
- `tron dev` is the only sanctioned Rust-server takeover of port `9847`; it uses `Tron-Dev.app` and the transient `com.tron.server.dev-takeover` label.
- Unknown listeners on port `9847` are blockers, not cleanup targets.
- Runtime cleanup preserves `profiles/`, `memory/`, `workspace/`, `vault/`, and `internal/database/` unless an explicit source-grounded reset flag says otherwise.
- iOS source is out of scope for this slice unless touched later; generated-project drift remains in scope.

## TSV Columns

`id`, `path`, `surface_kind`, `owner`, `runtime_owner`, `port_or_state`, `current_proof`, `risk`, `proof_target`, and `action_rationale`.

## Source Notes

The source-backed fix in this checkpoint is script hardening for port ownership. The Mac wrapper already checked process command ownership before stopping a dev server through the menu bar; the shell path now follows the same rule. Generated-project commands remain explicit closeout evidence rather than a new local deploy automation path.

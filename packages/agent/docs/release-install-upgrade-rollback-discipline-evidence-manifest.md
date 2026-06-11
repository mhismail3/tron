# Release / Install / Upgrade / Rollback Discipline Evidence Manifest

Status: **closed**
Current score: **100/100**
Branch: `codex/release-install-upgrade-rollback-discipline`
Base commit: `58c94586da6a01f1f7e3f23624ee523bd832ec86`

## Source Findings

- `scripts/tron` is the workspace dispatcher for development, CI, setup, contributor install, manual deploy, rollback, service controls, logs, auth, and version checks.
- `scripts/tron-cli` is the installed runtime CLI; it handles runtime commands directly and delegates workspace-only commands back to the recorded checkout.
- Production Mac install ownership is the Swift wrapper at `/Applications/Tron.app`, which registers bundled LaunchAgents through `SMAppService`. The shell contributor install path is explicitly workspace-only.
- `tron dev` intentionally takes over port `9847` from `com.tron.server`, wraps the dev binary in `~/.tron/internal/run/Tron-Dev.app`, and restores the installed helper through the wrapper start command.
- The source-grounded gap fixed in this slice is the CLI fallback that killed any lingering listener on port `9847`; it now fails closed unless the listener command is the known `Tron-Dev.app` helper.
- `tron status` now separates production helper registration from listener ownership: a loaded `com.tron.server` label without a port listener reports `prod_loaded_no_listener`, and an unknown listener reports `external_listener`.
- No iOS runtime source has been touched in this slice; iOS verification is the requested XcodeGen project drift check.

## Required Closeout Commands

| Command | Result | Notes |
|---|---|---|
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed | Formatting is stable after RUR invariant target formatting. |
| `cargo check --manifest-path packages/agent/Cargo.toml` | passed | Completed with the repo's existing dead-code warnings only. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture` | passed | New RUR invariant target covers artifacts, gates, port-owner discipline, loaded-no-listener status, generated drift commands, and stale-helper cleanup markers. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture` | passed | Predecessor preservation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture` | passed | Predecessor preservation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture` | passed | Predecessor preservation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture` | passed | Predecessor preservation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture` | passed | Predecessor preservation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture` | passed | Predecessor preservation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | passed_after_fix | Added RUR security-marker rows to the SACB inventory, then reran successfully. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture` | passed | Predecessor preservation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | passed | Primitive trace preservation. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | passed | Integration preservation. |
| `scripts/tron ci fmt check clippy test` | passed_after_fix | Initial runs exposed missing SACB/PCC inventory rows and invalid HRA row status; inventories were synchronized and the full local gate passed. |
| `scripts/personal-info-guard.sh` | passed | Full scan reported no personal-info leaks in source. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | Required iOS generated-project drift check; no iOS runtime source changed. |
| `cd packages/mac-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/mac-app/TronMac.xcodeproj` | passed | Required Mac generated-project drift check; Mac wrapper source was not changed. |
| `git diff --check` | passed | Unstaged whitespace guard passed. |
| `git ls-files -ci --exclude-standard` | passed | No tracked ignored files reported. |
| `git status --short` | passed | Only the staged RUR slice files were present before final commit. |

## Adversarial Audit Notes

- Production deploy automation did not expand: local and GitHub gates do not call `tron deploy`, `manual-deploy`, or contributor LaunchAgent install commands.
- Dev takeover now refuses unknown port `9847` listeners and only stops verified `Tron-Dev.app` helpers.
- Loaded production LaunchAgent state without a listener is classified as `prod_loaded_no_listener` rather than a running production server with an unknown PID; health remains false unless `/health` succeeds.
- Contributor uninstall removes known Tron labels, plist files, dev pid/log state, and app/support symlinks without deleting profiles, auth, database, workspace, memory, or vault data by default.
- The closeout intentionally did not install production LaunchAgents or run a production deployment command.

# Configuration / Profile / Environment Discipline Inventory

This inventory maps the configuration surfaces that can affect effective Tron settings, profile resolution, runtime environment, and client settings parity.

## Taxonomy

- `rust_schema`: canonical Rust settings types and validation.
- `profile_defaults`: bundled profile TOML and seeding/recovery.
- `sparse_overlay`: user override read/write paths.
- `profile_runtime`: bootstrap, active-profile resolution, runtime reload, and watcher behavior.
- `env_override`: environment variables that influence paths or settings.
- `script_env`: scripts and CI that export or consume runtime env.
- `ios_settings`: iOS settings decode/update/state/UI/tests.
- `mac_wrapper`: Mac wrapper settings/profile/env surfaces.
- `docs_ci`: README, scorecard, evidence, inventory, generated project, and CI wiring.
- `predecessor_inventory`: predecessor/current-lineage inventory links audited during this slice.

## Canonical Rules

1. Rust settings types under `packages/agent/src/domains/settings/profile/types/` are the canonical schema and defaults.
2. The bundled `packages/agent/defaults/profiles/default/profile.toml` must round-trip as `TronSettings` and match `TronSettings::default()`.
3. The sparse user overlay is `~/.tron/profiles/user/profile.toml`; writes must preserve unrelated overrides and must not copy managed defaults into the user profile.
4. Managed profile defaults are source-owned and recovered from compiled defaults; mutable `active.toml`, `auth.json`, and the user overlay are not silently overwritten.
5. Environment variables are explicit owner surfaces. `TRON_DATA_DIR` and `TRON_HOME_NAME` own path resolution; `TRON_DEFAULT_MODEL`, `TRON_DEFAULT_PROVIDER`, `TRON_HEARTBEAT_INTERVAL`, and `ANTHROPIC_CLIENT_ID` are the only settings env overrides in Rust.
6. iOS reads and writes server-authoritative settings through `settings::get`, `settings::update`, and `settings::reset_to_defaults`; malformed server settings payloads must surface as errors.
7. Mac wrapper settings writes are limited to the wrapper-owned `settings.server.tailscaleIp` cache in the sparse user overlay.

## User-Controlled And Server-Only Classification

The iOS user-controllable settings are `server.defaultModel`, `server.defaultWorkspace`, `context.compactor.preserveRecentCount`, `context.compactor.triggerTokenThreshold`, `observability.logLevel`, `observability.verboseRetentionDays`, `storage.retentionEnabled`, and `storage.maxDatabaseMb`. They have Swift decode, update, state, UI, and tests.

Other Rust settings are server-owned or implementation-owned defaults: provider OAuth URLs/client IDs/scopes, retry timing, compactor hard bounds, agent max turns, logging module overrides, heartbeat interval, tmux timing, empty session settings, and TUI palette/icon/input/menu settings. They remain profile-editable by source/user TOML but are not exposed as iOS controls because they either configure server internals, provider auth protocol, TUI-only behavior, or safety bounds that the mobile thin client should not mutate directly.

The machine-readable inventory is `configuration-profile-environment-discipline-inventory.tsv`.

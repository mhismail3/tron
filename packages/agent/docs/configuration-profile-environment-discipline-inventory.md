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

1. `TronSettings` under `packages/agent/src/domains/settings/profile/types/` is the canonical strict root schema; `ServerSettings` owns the Engine policy at `server.transcription.enabled`.
2. The bundled `packages/agent/defaults/profiles/default/profile.toml` must round-trip as `TronSettings` and match `TronSettings::default()`.
3. The sparse user overlay is `~/.tron/profiles/user/profile.toml`; writes must preserve unrelated overrides and must not copy managed defaults into the user profile.
4. Managed profile defaults are source-owned and recovered from compiled defaults; mutable `active.toml`, `auth.json`, and the user overlay are not silently overwritten.
5. Environment variables are explicit owner surfaces. `TRON_DATA_DIR` and `TRON_HOME_NAME` own path resolution; `TRON_DEFAULT_MODEL`, `TRON_HEARTBEAT_INTERVAL`, and `ANTHROPIC_CLIENT_ID` are the only settings env overrides in Rust.
6. iOS reads and writes server-authoritative settings through `settings::get`, `settings::update`, and `settings::reset_to_defaults`; malformed server settings payloads must surface as errors.
7. Mac wrapper settings writes are limited to the wrapper-owned `settings.server.tailscaleIp` cache in the sparse user overlay.
8. The project-reference Key Configuration catalog is a source-backed current-settings excerpt; documented default values must match `TronSettings::default()` and the managed default profile.

## User-Controlled And Server-Only Classification

The iOS user-controllable settings are `server.defaultModel`, `server.defaultWorkspace`, `context.compactor.preserveRecentCount`, `context.compactor.triggerTokenThreshold`, and server-owned `server.transcription.enabled`. They have Swift decode, update, state, UI, and tests, and Slice 21A guards that each entry remains present in the source-backed project-reference catalog plus the Swift decode/update/state/UI/parity chain.

Other Rust settings are server-owned or implementation-owned defaults: provider OAuth URLs/client IDs/scopes, retry timing, compactor hard bounds, agent max turns, heartbeat interval, tmux timing, empty session settings, and TUI palette/icon/input/menu settings. They remain profile-editable by source/user TOML but are not exposed as iOS controls because they either configure server internals, provider auth protocol, TUI-only behavior, or safety bounds that the mobile thin client should not mutate directly. Diagnostic verbosity defaults and filters, the seven-day diagnostic cleanup horizon, and the 512 MB active database budget are implementation-owned constants rather than profile settings.

The machine-readable inventory is `configuration-profile-environment-discipline-inventory.tsv`.

//! # settings
//!
//! Configuration management with layered sources for the Tron agent.
//!
//! Settings are loaded from three layers (in priority order):
//! 1. **Active profile settings** — `[settings]` in the resolved profile chain
//! 2. **User overlay** — `~/.tron/profiles/user/profile.toml` `[settings]`
//! 3. **Environment variables** — explicit settings overrides only:
//!    `TRON_DEFAULT_MODEL`, `TRON_HEARTBEAT_INTERVAL`, and
//!    `ANTHROPIC_CLIENT_ID`
//!
//! Settings are server-authoritative: `~/.tron/profiles/user/profile.toml` stores
//! sparse user overrides. `settings.get` returns the complete validated
//! [`TronSettings`] snapshot, while iOS intentionally admits only its explicit
//! product-settings projection and ignores unrelated provider, retry, runtime,
//! tmux, and TUI fields. iOS writes editable admitted fields through
//! `settings.update`; `settings.resetToDefaults` clears the complete sparse
//! server overlay before iOS projects the returned full profile. Device-only
//! preferences stay in the app's local storage, not here.
//! [`SettingsStore`] owns strict, atomic, serialized sparse-file writes.
//! Unknown nested settings keys are rejected so stale managed defaults and user
//! overlays fail closed instead of being silently ignored.
//!
//! `ProfileRuntime` is the sole owner of the current validated settings
//! snapshot. Capability writes persist through [`SettingsStore`], then the
//! settings operation asks `ProfileRuntime` to compile and atomically swap the
//! complete profile. Prompt runs keep the immutable snapshot captured at
//! admission; this persistence module owns no parallel runtime cache.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`storage`] | Profile file paths, sparse overlay loading, and deep merge |
//! | [`store`] | Atomic sparse settings persistence |
//! | [`types`] | Complete strict profile schema; iOS projects only its explicitly admitted product fields |
//! | `operations` | Canonical settings capability operations |
//! | [`db_path_policy`] | Database path guardrails |
//! | [`errors`] | Settings error hierarchy |
//!
//! ## Entry Points
//!
//! - [`SettingsStore`] owns strict settings persistence.
//! - [`load_settings_from_path`] loads one effective settings value for health
//!   checks and persistence validation.
//!
//! ## Dependency Direction
//!
//! Depends on: core foundation paths and profile defaults.
//! Depended on by: profile runtime, health checks, settings capability
//! operations, and iOS settings sync.
//! Constitution startup seeds and repairs managed profile files before the
//! settings loader reads them.
//! Loader-specific filesystem work stays under [`storage::loader`]; this root
//! exposes only narrow path and snapshot-loading facades needed by bootstrap,
//! health checks, profile runtime, and provider auth setup.
//!
//! ## Invariants
//!
//! - Server settings are authoritative and sparse user overrides stay in
//!   `profiles/user/profile.toml`.
//! - `settings.get` preserves the complete profile contract; mobile parity is
//!   enforced only for fields explicitly admitted by the iOS settings DTO.
//! - Local transcription remains a server-owned Engine policy at
//!   `server.transcription.enabled` and is mirrored by the iOS Engine page.
//! - Diagnostics verbosity, diagnostic retention, and database budgets are
//!   engine-managed policy, not mutable profile settings.
//! - Malformed settings and unknown nested settings keys fail fast instead of
//!   being silently repaired or ignored.
//! - JSON encode/decode implementation errors are mapped to [`SettingsError`]
//!   at the settings boundary before callers receive them.
//! - `ProfileRuntime` is the sole live settings owner; persistence helpers do
//!   not mutate runtime state.
//! - Successful settings operations persist first, then swap the compiled
//!   profile only through `ProfileRuntime`; rejected compiles restore the prior
//!   sparse file.
//!
//! ## Test Ownership
//!
//! Loader tests live in [`storage::loader`], persistence tests live in
//! [`store`], and schema/default tests live in [`types`].

#![deny(unsafe_code)]

pub mod db_path_policy;
pub mod errors;
pub(crate) mod operations;
pub mod storage;
pub mod store;
pub mod types;

pub use errors::{Result, SettingsError};
pub use store::SettingsStore;
pub use types::*;

use std::path::{Path, PathBuf};

/// Resolve the active sparse user profile settings path.
pub fn settings_path() -> PathBuf {
    storage::loader::settings_path()
}

/// Resolve the active provider auth path.
pub fn auth_path() -> PathBuf {
    storage::loader::auth_path()
}

/// Resolve the active Tron home used by profile-backed settings.
pub fn tron_home_dir() -> PathBuf {
    storage::loader::tron_home_dir()
}

/// Load an effective settings snapshot from a specific sparse profile path.
pub fn load_settings_from_path(path: &Path) -> Result<TronSettings> {
    storage::loader::load_settings_from_path(path)
}

/// Apply environment overrides to a settings snapshot.
pub(crate) fn apply_env_overrides(settings: &mut TronSettings) {
    storage::loader::apply_env_overrides(settings);
}

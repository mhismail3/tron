//! Typed engine settings and persistence.
//!
//! Effective settings are compiled defaults overlaid by the optional sparse
//! `~/.tron/settings.toml`, followed by the three explicit environment
//! overrides `TRON_DEFAULT_MODEL`, `TRON_HEARTBEAT_INTERVAL`, and
//! `ANTHROPIC_CLIENT_ID`. There are no named profiles, inheritance chains, or
//! active configuration pointers.
//!
//! [`SettingsStore`] owns strict serialized atomic writes. The sibling
//! `SettingsRuntime` owns the current immutable validated snapshot; an invalid
//! write or reload leaves both the running value and last valid sparse file
//! unchanged. Prompt runs retain the snapshot captured at admission.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`storage`] | Flat settings paths, sparse loading, deep merge, and environment overrides |
//! | [`store`] | Atomic sparse settings persistence |
//! | [`types`] | Complete strict settings schema; clients project explicitly admitted fields |
//! | `operations` | Canonical settings read/update/reset operations |
//! | `migration` | Snapshot-first one-time retirement of legacy named profiles |
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
//! Depends on: core foundation paths and compiled typed defaults.
//! Depended on by: settings runtime, health checks, provider setup, prompt
//! admission, and authenticated client settings sync.
//! Loader-specific filesystem work stays under [`storage::loader`]. Canonical
//! filesystem locations remain owned by the foundation path module instead of
//! being mirrored through behaviorless settings wrappers.
//!
//! ## Invariants
//!
//! - Server settings are authoritative and sparse user overrides stay in
//!   `~/.tron/settings.toml`.
//! - `settings.get` preserves the complete settings contract; mobile parity is
//!   enforced only for fields explicitly admitted by the iOS settings DTO.
//! - Malformed settings and unknown nested settings keys fail fast instead of
//!   being silently repaired or ignored.
//! - JSON encode/decode implementation errors are mapped to [`SettingsError`]
//!   at the settings boundary before callers receive them.
//! - `SettingsRuntime` is the sole live settings owner; persistence helpers do
//!   not mutate runtime state.
//! - Every admitted field changes an independent production consumer. Protocol
//!   constants owned by auth/provider code are not mirrored as inert settings.
//! - Successful settings operations persist first, then swap the effective
//!   snapshot only through `SettingsRuntime`; rejected reloads restore the prior
//!   sparse file.
//!
//! ## Test Ownership
//!
//! Loader tests live in [`storage::loader`], persistence tests live in
//! [`store`], and schema/default tests live in [`types`].

#![deny(unsafe_code)]

pub mod db_path_policy;
pub mod errors;
pub(crate) mod migration;
pub(crate) mod operations;
pub mod storage;
pub mod store;
pub mod types;

pub use errors::{Result, SettingsError};
pub use store::SettingsStore;
pub use types::*;

use std::path::Path;

/// Load an effective settings snapshot from a specific sparse settings file.
pub fn load_settings_from_path(path: &Path) -> Result<TronSettings> {
    storage::loader::load_settings_from_path(path)
}

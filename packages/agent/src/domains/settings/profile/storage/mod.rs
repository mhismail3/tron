//! Profile-backed settings storage.
//!
//! The settings domain stores sparse user overrides under
//! `~/.tron/profiles/user/profile.toml` and loads managed defaults from the
//! bundled profile tree. [`loader`] owns filesystem paths, default seeding,
//! sparse overlay decoding, deep merge, environment overrides, and drift checks
//! that keep bundled managed defaults aligned with compiled Rust defaults.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`loader`] | Resolve settings paths, seed defaults, load sparse overlays, merge defaults, apply environment overrides, and guard managed-default drift |
//!
//! ## Entry Points
//!
//! - [`loader::load_settings_from_path`] loads an effective settings snapshot
//!   for a specific sparse profile path.
//! - [`loader::seed_settings_defaults_for_path`] ensures managed defaults exist
//!   near a user profile path.
//! - [`loader::deep_merge`] applies sparse settings overlays.
//!
//! ## Dependency Direction
//!
//! Depends on foundation paths/profile defaults and settings types. Depended on
//! by [`super::store`], bootstrap, health checks, and tests that need isolated
//! profile roots.
//!
//! ## Invariants
//!
//! - Missing sparse user profiles mean defaults, not an implicit write.
//! - Invalid TOML, invalid settings shapes, and unknown nested settings keys
//!   return errors.
//! - Environment overrides apply after file/default merging.
//!
//! ## Test Ownership
//!
//! Loader tests live in [`loader`] because path resolution, sparse overlays,
//! and env override behavior are storage responsibilities.

pub mod loader;

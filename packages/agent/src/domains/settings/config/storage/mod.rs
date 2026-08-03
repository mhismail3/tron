//! Flat sparse-settings storage.
//!
//! The loader reads optional `~/.tron/settings.toml` over compiled typed
//! defaults. It owns sparse decoding, deep merge, and the small explicit
//! environment-override surface; canonical paths stay foundation-owned.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`loader`] | Load sparse overlays, merge defaults, and apply environment overrides |
//!
//! ## Entry Points
//!
//! - [`loader::load_settings_from_path`] loads an effective settings snapshot
//!   for a specific sparse settings path.
//! - [`loader::deep_merge`] applies sparse settings overlays.
//!
//! ## Dependency Direction
//!
//! Depends on foundation paths and settings types. Depended on
//! by [`super::store`], bootstrap, health checks, and tests that need isolated
//! settings roots.
//!
//! ## Invariants
//!
//! - A missing sparse settings file means defaults, not an implicit write.
//! - Invalid TOML, invalid settings shapes, and unknown nested settings keys
//!   return errors.
//! - Environment overrides apply after file/default merging.
//!
//! ## Test Ownership
//!
//! Loader tests live in [`loader`] because path resolution, sparse overlays,
//! and env override behavior are storage responsibilities.

pub mod loader;

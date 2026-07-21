//! Flat engine-settings domain.
//!
//! This module owns the typed schema, sparse `~/.tron/settings.toml` storage,
//! atomic runtime snapshot, authenticated settings operations, and snapshot-first
//! retirement of the old named-profile plane. Each admitted prompt run captures
//! one immutable settings snapshot.

pub mod config;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod runtime;
pub(crate) use config::migration::LegacyProfileRetirement;
pub(crate) use config::operations::{settings_reset_to_defaults_value, settings_update_value};
pub use config::*;
pub(crate) use deps::Deps;
pub use runtime::{SettingsRuntime, SettingsSnapshot};

use crate::domains::registration::module::DomainModule;
use crate::domains::registration::module::DomainRegistrationContext;

pub(crate) fn function_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::registration::module::domain_module(
            "settings",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

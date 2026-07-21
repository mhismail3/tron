//! Flat engine-settings domain.
//!
//! This module owns the typed schema, sparse `~/.tron/settings.toml` storage,
//! atomic runtime snapshot, and authenticated settings operations. Each
//! admitted prompt run captures one immutable settings snapshot.

pub mod config;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod runtime;
pub(crate) use config::operations::{settings_reset_to_defaults_value, settings_update_value};
pub use config::*;
pub(crate) use deps::Deps;
pub use runtime::{SettingsRuntime, SettingsSnapshot};

use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};

pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    handlers::bind_functions(contract::function_definitions()?, Deps::from_engine(deps))
}

//! auth domain worker.
//!
//! This module owns canonical function execution for the auth namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Credential reads/writes and account selection live under `credentials/`.
//! OAuth provider routing, flow state, and completion live under `oauth/` and
//! are shared by engine functions and the contributor CLI bridge. This root
//! only registers the auth worker and exposes the concrete ownership modules.

pub(crate) mod contract;
pub mod credentials;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod oauth;
pub(crate) mod stream;
pub(crate) use deps::Deps;

use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};

pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    handlers::bind_functions(contract::capabilities()?, Deps::from_engine(deps))
}

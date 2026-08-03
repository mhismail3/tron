//! auth domain worker.
//!
//! This module owns canonical function execution for the auth namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Model/search credential reads, writes, and account selection live under
//! `credentials/`.
//! OAuth provider routing, flow state, and completion live under `oauth/` and
//! are shared by engine functions and the contributor CLI bridge. This root
//! only registers the auth worker and exposes the concrete ownership modules.
//! Apple Push provider-token credentials are a typed transport entry under
//! `credentials/apple_push`; they never enter model-provider auth state.
//! Relay/direct notification transport selection and relay HMAC credentials
//! are independently owned by `credentials/notification_push`.

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
    handlers::bind_functions(contract::function_definitions()?, Deps::from_engine(deps))
}

//! model domain worker.
//!
//! This module owns canonical function execution for the model namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Model listing, switching, and provider-neutral registry helpers
//! live under `routing/`.
//! Provider-native stream and function-call details are isolated under
//! `providers/`, `protocol/`, and the `responder/` boundary before being
//! converted to canonical capability history;
//! malformed provider capability arguments fail closed at that boundary.
//! Token normalization, pricing, and token record types live under `tokens/`
//! because they are canonical model-domain accounting, not provider wiring.
//! Effective attachment limits live under `routing::attachments`; `model.list`
//! publishes them and the agent prompt boundary enforces the same policy so
//! clients never need provider-name heuristics.
//! Provider request audits redact hidden reasoning and sensitive material before
//! bounded persistence; normalized reasoning token counts remain part of the
//! ordinary token-accounting path.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod protocol;
pub(crate) mod providers;
pub mod responder;
pub mod routing;
pub mod tokens;
pub(crate) use deps::Deps;

use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};

pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    let model_definitions = contract::function_definitions()?;
    let domain_deps = Deps::from_engine(deps);
    handlers::model::bind_functions(model_definitions, domain_deps)
}

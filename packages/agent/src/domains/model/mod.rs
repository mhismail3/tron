//! model domain worker.
//!
//! This module owns canonical function execution for the model namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Model listing, model switching, reasoning-level mutation, and product preset
//! routing live here. `presets` owns the server-side `Local when possible`,
//! `Balanced`, and `Deep` vocabulary plus selected-model/hosted-route presentation
//! used by automations and subagents.
//! Operation bodies live in `operations/`; provider catalog helpers remain in `catalog.rs`.
//! Provider-native stream and function-call details are isolated under
//! `provider_protocol` before being converted to canonical capability history;
//! malformed provider capability arguments fail closed at that boundary.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub mod presets;
pub mod provider_protocol;
pub mod providers;
pub(crate) use deps::Deps;
pub use providers::*;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;

pub(crate) fn worker_modules(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainWorkerModule>> {
    let contracts = contract::capabilities()?;
    let model_specs = contracts
        .iter()
        .filter(|spec| spec.owner_worker.as_str() == "model")
        .cloned()
        .collect::<Vec<_>>();
    let config_specs = contracts
        .into_iter()
        .filter(|spec| spec.owner_worker.as_str() == "config")
        .collect::<Vec<_>>();
    let domain_deps = Deps::from_engine(deps);
    Ok(vec![
        crate::domains::worker::domain_worker_module(
            "model",
            contract::STREAM_TOPICS,
            handlers::model::function_registrations(model_specs, domain_deps.clone())?,
        )?,
        crate::domains::worker::domain_worker_module(
            "config",
            contract::STREAM_TOPICS,
            handlers::config::function_registrations(config_specs, domain_deps)?,
        )?,
    ])
}

pub(crate) mod catalog;

//! model domain worker.
//!
//! This module owns canonical function execution for the model namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Model listing, model switching, and reasoning-level mutation operation
//! bodies live in `operations/`; provider catalog helpers remain in `catalog.rs`.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;

use super::*;

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
        super::domain_worker_module(
            "model",
            contract::STREAM_TOPICS,
            handlers::model::function_registrations(model_specs, domain_deps.clone())?,
        )?,
        super::domain_worker_module(
            "config",
            contract::STREAM_TOPICS,
            handlers::config::function_registrations(config_specs, domain_deps)?,
        )?,
    ])
}

pub(crate) mod catalog;

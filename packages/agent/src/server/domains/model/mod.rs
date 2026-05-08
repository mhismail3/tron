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
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_modules(
    deps: &DomainSetupContext,
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
    Ok(vec![
        super::domain_worker_module(
            "model",
            contract::STREAM_TOPICS,
            model_specs,
            Deps::from_engine(deps),
            super::model_handler,
        )?,
        super::domain_worker_module(
            "config",
            contract::STREAM_TOPICS,
            config_specs,
            Deps::from_engine(deps),
            super::model_handler,
        )?,
    ])
}

pub(crate) mod catalog;

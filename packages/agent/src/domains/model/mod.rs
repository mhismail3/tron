//! model domain worker.
//!
//! This module owns canonical function execution for the model namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Model listing and model switching live here. Provider presets remain
//! internal provider metadata, not a session event surface.
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
    let model_specs = contract::capabilities()?;
    let domain_deps = Deps::from_engine(deps);
    Ok(vec![crate::domains::worker::domain_worker_module(
        "model",
        contract::STREAM_TOPICS,
        handlers::model::function_registrations(model_specs, domain_deps)?,
    )?])
}

pub(crate) mod catalog;

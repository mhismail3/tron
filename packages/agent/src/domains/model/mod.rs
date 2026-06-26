//! model domain worker.
//!
//! This module owns canonical function execution for the model namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Model listing, switching, presets, and provider-neutral registry helpers
//! live under `routing/`.
//! Provider-native stream and function-call details are isolated under
//! `providers/`, `protocol/`, and the `responder/` boundary before being
//! converted to canonical capability history;
//! malformed provider capability arguments fail closed at that boundary.
//! Token normalization, pricing, and token record types live under `tokens/`
//! because they are canonical model-domain accounting, not provider wiring.
//! Provider reasoning/status evidence is metadata-only and stays in the
//! responder/audit plus token-accounting boundary; it must not expose hidden
//! reasoning text, synthesize summaries, or add model-visible tools.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod protocol;
pub(crate) mod providers;
pub mod responder;
pub mod routing;
pub mod tokens;
pub(crate) use deps::Deps;

use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::registration::worker::DomainWorkerModule;

pub(crate) fn worker_modules(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainWorkerModule>> {
    let model_specs = contract::capabilities()?;
    let domain_deps = Deps::from_engine(deps);
    Ok(vec![
        crate::domains::registration::worker::domain_worker_module(
            "model",
            contract::STREAM_TOPICS,
            handlers::model::function_registrations(model_specs, domain_deps)?,
        )?,
    ])
}

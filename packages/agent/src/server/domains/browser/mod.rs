//! browser domain worker.
//!
//! This module owns canonical function execution for the browser namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;

use super::*;

pub(crate) fn worker_module(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "browser",
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::browser_handler,
    )
}
#[derive(Clone)]
pub(crate) struct Deps;

impl Deps {
    pub(crate) fn from_engine(_deps: &EngineCapabilityDeps) -> Self {
        Self
    }
}

pub(super) async fn handle(method: &str, _deps: &Deps) -> Result<Value, CapabilityError> {
    match method {
        "browser::get_status" => Ok(json!({
            "hasBrowser": false,
            "isStreaming": false,
        })),
        _ => Err(CapabilityError::Internal {
            message: format!("browser method {method} is not engine-owned"),
        }),
    }
}

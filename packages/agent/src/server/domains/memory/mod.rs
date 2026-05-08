//! memory domain worker.
//!
//! This module owns canonical function execution for the memory namespace and keeps
//! domain services, schemas, and tests beside the worker that uses them.

pub(crate) mod spec;

use super::*;

pub(crate) mod retain;

use crate::server::domains::memory::retain as memory_retain;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    match method {
        "memory::retain" => retain_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("memory method {method} is not engine-owned"),
        }),
    }
}

async fn retain_value(
    payload: &Value,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    memory_retain::trigger_manual_retain(Some(payload), &deps.capability_context).await
}

//! browser domain worker.
//!
//! This module owns canonical function execution for the browser namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod spec;

use super::*;
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
        "browser::start_stream" => Err(CapabilityError::NotAvailable {
            message: "Browser streaming has been removed".into(),
        }),
        "browser::stop_stream" => Ok(json!({ "success": true })),
        _ => Err(CapabilityError::Internal {
            message: format!("browser method {method} is not engine-owned"),
        }),
    }
}

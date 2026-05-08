//! browser domain worker.
//!
//! This module owns canonical function execution for the browser namespace and keeps
//! domain services, schemas, and tests beside the worker that uses them.

pub(crate) mod spec;

use super::*;

pub(super) async fn handle(method: &str) -> Result<Value, CapabilityError> {
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

//! JSON-RPC error mapping for capability errors.
//!
//! Canonical capabilities return transport-neutral [`CapabilityError`] values.
//! This module is the only JSON-RPC boundary that turns those errors into the
//! WebSocket wire shape.
//!
//! INVARIANT: Under the trusted-local threat model, JSON-RPC error mapping is
//! transport-only. Domain services and capability handlers must create
//! `CapabilityError`s, never `JsonRpcErrorBody`s.

use crate::server::capabilities::errors::{self as capability_errors, CapabilityError};
use crate::server::transport::json_rpc::types::JsonRpcErrorBody;

pub use capability_errors::METHOD_NOT_FOUND;

/// Convert a capability error into the JSON-RPC wire error body.
pub fn to_error_body(error: &CapabilityError) -> JsonRpcErrorBody {
    JsonRpcErrorBody {
        code: error.code().to_owned(),
        message: error.to_string(),
        details: error.details(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_capability_error_without_details() {
        let error = CapabilityError::NotAvailable {
            message: "nope".to_owned(),
        };
        let body = to_error_body(&error);
        assert_eq!(body.code, capability_errors::NOT_AVAILABLE);
        assert_eq!(body.message, "nope");
        assert!(body.details.is_none());
    }

    #[test]
    fn maps_capability_error_with_details() {
        let error = CapabilityError::Custom {
            code: "MY_CODE".to_owned(),
            message: "custom".to_owned(),
            details: Some(serde_json::json!({"x": 1})),
        };
        let body = to_error_body(&error);
        assert_eq!(body.code, "MY_CODE");
        assert_eq!(body.details.unwrap()["x"], 1);
    }
}

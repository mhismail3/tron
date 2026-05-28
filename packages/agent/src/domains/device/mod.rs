//! device domain worker.
//!
//! This module owns canonical function execution for the device namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::context::run_blocking_task;
use serde_json::json;
use std::sync::Arc;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "device",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

use crate::shared::server::error_mapping::map_event_store_error;
use crate::shared::server::params::{opt_string, require_string_param};

// INVARIANT: device.register accepts a client-supplied bundleId only under the
// trusted-local model: paired clients are the user's own devices on the local
// network/Tailscale path, and the value is used as local APNs routing metadata,
// not as proof of device identity. If Tron exposes this capability beyond
// trusted-local callers, registration must bind bundleId to an authenticated
// app/device attestation claim before writing it to the event store.

const MIN_APNS_TOKEN_HEX_LEN: usize = 2;
const MAX_APNS_TOKEN_HEX_LEN: usize = 512;

fn validate_apns_token(device_token: &str) -> Result<(), CapabilityError> {
    let len = device_token.len();
    if len < MIN_APNS_TOKEN_HEX_LEN
        || len > MAX_APNS_TOKEN_HEX_LEN
        || len % 2 != 0
        || !device_token.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Invalid device token: expected an even-length hex APNs token between {MIN_APNS_TOKEN_HEX_LEN} and {MAX_APNS_TOKEN_HEX_LEN} chars, got {len} chars"
            ),
        });
    }
    Ok(())
}

async fn register_token(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let device_token = require_string_param(Some(payload), "deviceToken")?;
    validate_apns_token(&device_token)?;

    let session_id = opt_string(Some(payload), "sessionId");
    let workspace_id = opt_string(Some(payload), "workspaceId");
    let environment = opt_string(Some(payload), "environment");
    let bundle_id = require_string_param(Some(payload), "bundleId")?;
    if bundle_id.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "bundleId must not be empty".into(),
        });
    }

    let event_store = Arc::clone(&deps.event_store);
    run_blocking_task("device::register", move || {
        let result = event_store
            .register_device_token(
                &device_token,
                session_id.as_deref(),
                workspace_id.as_deref(),
                environment.as_deref().unwrap_or("production"),
                &bundle_id,
            )
            .map_err(map_event_store_error)?;
        Ok(json!({
            "id": result.id,
            "created": result.created,
        }))
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::validate_apns_token;

    #[test]
    fn apns_token_validation_accepts_variable_even_length_hex_tokens() {
        validate_apns_token(&"a".repeat(64)).expect("historical 32-byte APNs token is valid");
        validate_apns_token(&"b".repeat(160))
            .expect("modern/simulator APNs token lengths are variable");
    }

    #[test]
    fn apns_token_validation_rejects_malformed_or_unbounded_tokens() {
        for token in ["", "a", "zz", "abc"] {
            assert!(validate_apns_token(token).is_err(), "{token:?} should fail");
        }
        let too_long = "a".repeat(514);
        assert!(validate_apns_token(&too_long).is_err());
    }
}

async fn unregister_token(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let device_token = require_string_param(Some(payload), "deviceToken")?;
    let event_store = Arc::clone(&deps.event_store);
    run_blocking_task("device::unregister", move || {
        let success = event_store
            .unregister_device_token(&device_token)
            .map_err(map_event_store_error)?;
        Ok(json!({ "success": success }))
    })
    .await
}

async fn respond(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let request_id = require_string_param(Some(payload), "requestId")?;
    let result = payload.get("result").cloned().unwrap_or(Value::Null);
    if let Some(ref broker) = deps.device_request_broker {
        let resolved = broker.resolve(&request_id, result);
        Ok(json!({ "resolved": resolved }))
    } else {
        Err(CapabilityError::Internal {
            message: "Device request broker not available".into(),
        })
    }
}

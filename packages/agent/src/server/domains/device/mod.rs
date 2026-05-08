//! device domain worker.
//!
//! This module owns canonical function execution for the device namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;

use super::*;

pub(crate) fn worker_module(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "device",
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::device_handler,
    )
}
#[derive(Clone)]
pub(crate) struct Deps {
    capability_context: Arc<ServerCapabilityContext>,
    event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            capability_context: deps.capability_context.clone(),
            event_store: deps.event_store.clone(),
        }
    }
}

use crate::server::shared::error_mapping::map_event_store_error;
use crate::server::shared::params::{opt_string, require_string_param};

// INVARIANT: device.register accepts a client-supplied bundleId only under the
// trusted-local model: paired clients are the user's own devices on the local
// network/Tailscale path, and the value is used as local APNs routing metadata,
// not as proof of device identity. If Tron exposes this capability beyond
// trusted-local callers, registration must bind bundleId to an authenticated
// app/device attestation claim before writing it to the event store.

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "device::register" => register_token(&invocation.payload, deps).await,
        "device::unregister" => unregister_token(&invocation.payload, deps).await,
        "device::respond" => respond(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("device method {method} is not engine-owned"),
        }),
    }
}

async fn register_token(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let device_token = require_string_param(Some(payload), "deviceToken")?;
    if device_token.len() != 64 || !device_token.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Invalid device token: expected 64 hex chars, got {} chars",
                device_token.len()
            ),
        });
    }

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
    deps.capability_context
        .run_blocking("device::register", move || {
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

async fn unregister_token(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let device_token = require_string_param(Some(payload), "deviceToken")?;
    let event_store = Arc::clone(&deps.event_store);
    deps.capability_context
        .run_blocking("device::unregister", move || {
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
    if let Some(ref broker) = deps.capability_context.device_request_broker {
        let resolved = broker.resolve(&request_id, result);
        Ok(json!({ "resolved": resolved }))
    } else {
        Err(CapabilityError::Internal {
            message: "Device request broker not available".into(),
        })
    }
}

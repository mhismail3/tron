//! blob domain worker.
//!
//! This module owns the small blob namespace end-to-end: contract metadata,
//! handler binding, and operation execution. Handlers borrow the shared event
//! store directly and own no parallel dependency or storage-state container.

use base64::Engine;

use crate::domains::registration::bindings::operation_bindings;
use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};
use crate::domains::registration::contract::FunctionContract;
use crate::domains::session::event_store::EventStore;
use crate::engine::{EffectClass, FunctionDefinition, Result as EngineResult, RiskLevel};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    bind_functions(function_definitions()?, Arc::clone(&deps.event_store))
}

pub(crate) fn function_definitions() -> EngineResult<Vec<FunctionDefinition>> {
    Ok(vec![
        FunctionContract::new(
            "blob::get",
            "blob",
            EffectClass::PureRead,
            RiskLevel::Low)
        .request_schema(json!({"additionalProperties":false,"properties":{"blobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["blobId"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"blobId":{"type":"string"},"data":{"type":"string"},"mimeType":{"type":"string"},"sizeBytes":{"type":"integer"}},"required":["blobId","mimeType","data","sizeBytes"],"type":"object"}))
        .build()?,
    ])
}

operation_bindings! {
    deps = Arc<EventStore>;
    hidden = [];
    bindings = [
        "get" => |invocation, deps| {
            blob_get_value(&invocation.payload, deps).await
        },
    ];
}

async fn blob_get_value(
    payload: &Value,
    event_store: &Arc<EventStore>,
) -> Result<Value, CapabilityError> {
    let blob_id = payload
        .get("blobId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "missing 'blobId' parameter".into(),
        })?
        .to_owned();
    let event_store = Arc::clone(event_store);
    run_blocking_task("blob::get", move || {
        let blob = event_store
            .get_blob(&blob_id)
            .map_err(|error| CapabilityError::Internal {
                message: format!("blob lookup error: {error}"),
            })?
            .ok_or_else(|| CapabilityError::NotFound {
                code: "BLOB_NOT_FOUND".into(),
                message: format!("blob not found: {blob_id}"),
            })?;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&blob.content);
        Ok(json!({
            "blobId": blob_id,
            "mimeType": blob.mime_type,
            "data": b64,
            "sizeBytes": blob.content.len(),
        }))
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::server::test_support::make_test_context;

    #[tokio::test]
    async fn get_returns_stored_blob_metadata_and_content() {
        let event_store = make_test_context().event_store;
        let blob_id = event_store
            .store_blob(b"hello", "text/plain")
            .expect("store blob");

        let value = blob_get_value(&json!({"blobId": blob_id}), &event_store)
            .await
            .expect("get blob");

        assert_eq!(value["blobId"], blob_id);
        assert_eq!(value["mimeType"], "text/plain");
        assert_eq!(value["data"], "aGVsbG8=");
        assert_eq!(value["sizeBytes"], 5);
    }
}

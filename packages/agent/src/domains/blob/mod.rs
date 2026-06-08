//! blob domain worker.
//!
//! This module owns the small blob namespace end-to-end: contract metadata,
//! registration dependencies, handler binding, and operation execution.

use base64::Engine;

use crate::domains::bindings::operation_bindings;
use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

const STREAM_TOPICS: &[&str] = &[];

#[derive(Clone)]
pub(crate) struct Deps {
    event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
        }
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "blob",
            STREAM_TOPICS,
            function_registrations(capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "blob::get",
            "blob",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("blob.read"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"blobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["blobId"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"blobId":{"type":"string"},"data":{"type":"string"},"mimeType":{"type":"string"},"sizeBytes":{"type":"integer"}},"required":["blobId","mimeType","data","sizeBytes"],"type":"object"}))
        .build()?,
    ])
}

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get" => |invocation, deps| {
            blob_get_value(&invocation.payload, deps).await
        },
    ];
}

async fn blob_get_value(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let blob_id = payload
        .get("blobId")
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "missing 'blobId' parameter".into(),
        })?
        .to_owned();
    let pool = deps.event_store.pool().clone();
    run_blocking_task("blob::get", move || {
        let conn = pool.get().map_err(|error| CapabilityError::Internal {
            message: format!("database connection error: {error}"),
        })?;
        let blob =
            crate::domains::session::event_store::sqlite::repositories::blob::BlobRepo::get_by_id(
                &conn, &blob_id,
            )
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

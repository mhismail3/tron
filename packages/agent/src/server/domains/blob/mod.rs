//! blob domain worker.
//!
//! This module owns canonical function execution for the blob namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use base64::Engine;

use crate::server::domains::worker::DomainRegistrationContext;
use crate::server::domains::worker::DomainWorkerModule;
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::server::domains::worker::domain_worker_module(
            "blob",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
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
        let blob = crate::events::sqlite::repositories::blob::BlobRepo::get_by_id(&conn, &blob_id)
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

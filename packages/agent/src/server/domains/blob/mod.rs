//! blob domain worker.
//!
//! This module owns canonical function execution for the blob namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod spec;

use base64::Engine;

use super::*;
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

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "blob::get" => blob_get_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("blob method {method} is not engine-owned"),
        }),
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
    deps.capability_context
        .run_blocking("blob::get", move || {
            let conn = pool.get().map_err(|error| CapabilityError::Internal {
                message: format!("database connection error: {error}"),
            })?;
            let blob =
                crate::events::sqlite::repositories::blob::BlobRepo::get_by_id(&conn, &blob_id)
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

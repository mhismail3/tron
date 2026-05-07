use base64::Engine;

use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    match method {
        "blob.get" => blob_get_value(&invocation.payload, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("blob method {method} is not engine-owned"),
        }),
    }
}

async fn blob_get_value(payload: &Value, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let blob_id = payload
        .get("blobId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::InvalidParams {
            message: "missing 'blobId' parameter".into(),
        })?
        .to_owned();
    let pool = deps.event_store.pool().clone();
    deps.rpc_context
        .run_blocking("blob.get", move || {
            let conn = pool.get().map_err(|error| RpcError::Internal {
                message: format!("database connection error: {error}"),
            })?;
            let blob =
                crate::events::sqlite::repositories::blob::BlobRepo::get_by_id(&conn, &blob_id)
                    .map_err(|error| RpcError::Internal {
                        message: format!("blob lookup error: {error}"),
                    })?
                    .ok_or_else(|| RpcError::NotFound {
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

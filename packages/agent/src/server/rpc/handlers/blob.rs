//! Blob retrieval RPC handler.
//!
//! Allows the iOS app to fetch binary content (images, etc.) stored in blob
//! storage. The Display tool stores images as blobs and includes only the
//! `blobId` in event details; the client fetches the actual data via this RPC.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::registry::MethodHandler;

/// Fetch blob content by ID. Returns base64-encoded data + MIME type.
pub struct GetBlobHandler;

#[async_trait]
impl MethodHandler for GetBlobHandler {
    #[instrument(skip(self, ctx), fields(method = "blob.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let params = params.ok_or_else(|| RpcError::InvalidParams {
            message: "missing params".into(),
        })?;
        let blob_id = params
            .get("blobId")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::InvalidParams {
                message: "missing 'blobId' parameter".into(),
            })?;

        let pool = ctx.event_store.pool();
        let conn = pool.get().map_err(|e| RpcError::Internal {
            message: format!("database connection error: {e}"),
        })?;

        let blob = crate::events::sqlite::repositories::blob::BlobRepo::get_by_id(&conn, blob_id)
            .map_err(|e| RpcError::Internal {
                message: format!("blob lookup error: {e}"),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: "BLOB_NOT_FOUND".into(),
                message: format!("blob not found: {blob_id}"),
            })?;

        let b64 = base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            &blob.content,
        );

        Ok(serde_json::json!({
            "blobId": blob_id,
            "mimeType": blob.mime_type,
            "data": b64,
            "sizeBytes": blob.content.len(),
        }))
    }
}

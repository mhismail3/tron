//! Logs handler: export.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Resolve the iOS logs directory path.
fn ios_logs_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    std::path::PathBuf::from(home)
        .join(".tron")
        .join("artifacts")
        .join("ios-logs")
}

/// Export iOS logs to server filesystem.
pub struct ExportLogsHandler;

#[async_trait]
impl MethodHandler for ExportLogsHandler {
    #[instrument(skip(self, _ctx), fields(method = "logs.export"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let content = require_string_param(params.as_ref(), "content")?;

        let logs_dir = ios_logs_dir();

        let _ = std::fs::create_dir_all(&logs_dir);

        let filename = format!(
            "ios-log-{}.txt",
            chrono::Utc::now().format("%Y%m%d-%H%M%S")
        );
        let path = logs_dir.join(&filename);

        let bytes_written = content.len();
        std::fs::write(&path, &content).map_err(|e| RpcError::Internal {
            message: format!("Failed to write log file: {e}"),
        })?;

        Ok(serde_json::json!({
            "success": true,
            "path": path.to_string_lossy(),
            "bytesWritten": bytes_written,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[test]
    fn ios_logs_dir_uses_artifacts_path() {
        let dir = ios_logs_dir();
        let path = dir.to_string_lossy();
        assert!(
            path.ends_with(".tron/artifacts/ios-logs"),
            "expected path ending in .tron/artifacts/ios-logs, got: {path}"
        );
    }

    #[tokio::test]
    async fn export_logs_writes_file_and_returns_success() {
        let ctx = make_test_context();
        let result = ExportLogsHandler
            .handle(Some(json!({"content": "test log data"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["success"], true);
        assert_eq!(result["bytesWritten"], 13);

        // Verify file was actually written
        let path = result["path"].as_str().unwrap();
        assert!(path.contains("artifacts/ios-logs/"), "path should use artifacts/ios-logs, got: {path}");
        let content = std::fs::read_to_string(path).unwrap();
        assert_eq!(content, "test log data");

        // Clean up test artifact
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn export_logs_missing_content() {
        let ctx = make_test_context();
        let err = ExportLogsHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}

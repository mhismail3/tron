//! Logs handler: export.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Export iOS logs to server filesystem.
pub struct ExportLogsHandler;

#[async_trait]
impl MethodHandler for ExportLogsHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let content = require_string_param(params.as_ref(), "content")?;

        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
        let logs_dir = std::path::PathBuf::from(home)
            .join(".tron")
            .join("ios-logs");

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
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn export_logs_returns_success() {
        let ctx = make_test_context();
        let result = ExportLogsHandler
            .handle(Some(json!({"content": "test log data"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert!(result["path"].is_string());
        assert_eq!(result["bytesWritten"], 13);
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

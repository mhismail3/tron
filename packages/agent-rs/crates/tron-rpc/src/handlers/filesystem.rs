//! Filesystem handlers: listDir, getHome, createDir, file.read.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// List directory contents.
pub struct ListDirHandler;

#[async_trait]
impl MethodHandler for ListDirHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = require_string_param(params.as_ref(), "path")?;

        let entries = std::fs::read_dir(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                RpcError::NotFound {
                    code: errors::FILE_NOT_FOUND.into(),
                    message: format!("Directory not found: {path}"),
                }
            } else {
                RpcError::Custom {
                    code: errors::FILESYSTEM_ERROR.into(),
                    message: e.to_string(),
                    details: None,
                }
            }
        })?;

        let items: Vec<Value> = entries
            .filter_map(std::result::Result::ok)
            .map(|e| {
                let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
                serde_json::json!({
                    "name": e.file_name().to_string_lossy(),
                    "isDirectory": is_dir,
                })
            })
            .collect();

        Ok(serde_json::json!({ "entries": items }))
    }
}

/// Get user home directory.
pub struct GetHomeHandler;

#[async_trait]
impl MethodHandler for GetHomeHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
        Ok(serde_json::json!({ "home": home }))
    }
}

/// Create a directory (recursive).
pub struct CreateDirHandler;

#[async_trait]
impl MethodHandler for CreateDirHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = require_string_param(params.as_ref(), "path")?;

        std::fs::create_dir_all(&path).map_err(|e| RpcError::Custom {
            code: errors::FILESYSTEM_ERROR.into(),
            message: e.to_string(),
            details: None,
        })?;

        Ok(serde_json::json!({ "created": true, "path": path }))
    }
}

/// Read file contents.
pub struct ReadFileHandler;

#[async_trait]
impl MethodHandler for ReadFileHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = require_string_param(params.as_ref(), "path")?;

        let content = std::fs::read_to_string(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                RpcError::NotFound {
                    code: errors::FILE_NOT_FOUND.into(),
                    message: format!("File not found: {path}"),
                }
            } else {
                RpcError::Custom {
                    code: errors::FILE_ERROR.into(),
                    message: e.to_string(),
                    details: None,
                }
            }
        })?;

        Ok(serde_json::json!({ "content": content, "path": path }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn list_dir_success() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        assert!(result["entries"].is_array());
    }

    #[tokio::test]
    async fn list_dir_not_found() {
        let ctx = make_test_context();
        let err = ListDirHandler
            .handle(
                Some(json!({"path": "/nonexistent_dir_xyz_12345"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "FILE_NOT_FOUND");
    }

    #[tokio::test]
    async fn list_dir_missing_param() {
        let ctx = make_test_context();
        let err = ListDirHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn get_home() {
        let ctx = make_test_context();
        let result = GetHomeHandler.handle(None, &ctx).await.unwrap();
        assert!(result["home"].is_string());
        assert!(!result["home"].as_str().unwrap().is_empty());
    }

    #[tokio::test]
    async fn read_file_not_found() {
        let ctx = make_test_context();
        let err = ReadFileHandler
            .handle(
                Some(json!({"path": "/nonexistent_file_xyz_12345.txt"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "FILE_NOT_FOUND");
    }

    #[tokio::test]
    async fn read_file_missing_param() {
        let ctx = make_test_context();
        let err = ReadFileHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}

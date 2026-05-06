//! Filesystem handlers: listDir, createDir, file.read.
//!
//! `filesystem.getHome` is served by the engine bridge generic trigger.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::filesystem_service;
use crate::server::rpc::handlers::{opt_bool, opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;

/// List directory contents.
pub struct ListDirHandler;

#[async_trait]
impl MethodHandler for ListDirHandler {
    #[instrument(skip(self, ctx), fields(method = "filesystem.listDir"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let home = crate::core::paths::home_dir();
        let path = opt_string(params.as_ref(), "path").unwrap_or(home);
        let show_hidden = opt_bool(params.as_ref(), "showHidden").unwrap_or(false);

        ctx.run_blocking("filesystem.listDir", move || {
            filesystem_service::list_dir(&path, show_hidden)
        })
        .await
    }
}

/// Create a directory (recursive).
pub struct CreateDirHandler;

#[async_trait]
impl MethodHandler for CreateDirHandler {
    #[instrument(skip(self, ctx), fields(method = "filesystem.mkdir"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = require_string_param(params.as_ref(), "path")?;
        ctx.run_blocking("filesystem.mkdir", move || {
            filesystem_service::create_dir(&path)
        })
        .await
    }
}

/// Read file contents.
pub struct ReadFileHandler;

#[async_trait]
impl MethodHandler for ReadFileHandler {
    #[instrument(skip(self, ctx), fields(method = "file.read"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = require_string_param(params.as_ref(), "path")?;
        ctx.run_blocking("file.read", move || filesystem_service::read_file(&path))
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::RpcRequest;
    use serde_json::json;

    async fn get_home_result(ctx: &RpcContext) -> Value {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "test-filesystem-get-home".to_owned(),
                    method: "filesystem.getHome".to_owned(),
                    params: Some(json!({})),
                },
                ctx,
            )
            .await;
        assert!(response.success, "filesystem.getHome: {:?}", response.error);
        response.result.unwrap()
    }

    #[tokio::test]
    async fn list_dir_success() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        assert!(result["entries"].is_array());
        assert_eq!(result["path"], "/tmp");
        assert!(result["parent"].is_string());
    }

    #[tokio::test]
    async fn list_dir_entries_have_full_fields() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        let entries = result["entries"].as_array().unwrap();
        for entry in entries {
            assert!(entry["name"].is_string());
            assert!(entry["path"].is_string());
            assert!(entry.get("isDirectory").is_some());
            assert!(entry.get("isSymlink").is_some());
        }
    }

    #[tokio::test]
    async fn list_dir_defaults_to_home() {
        let ctx = make_test_context();
        let result = ListDirHandler.handle(Some(json!({})), &ctx).await.unwrap();
        assert!(result["entries"].is_array());
        assert!(result["path"].is_string());
    }

    #[tokio::test]
    async fn list_dir_not_found() {
        let ctx = make_test_context();
        let err = ListDirHandler
            .handle(Some(json!({"path": "/nonexistent_dir_xyz_12345"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "FILE_NOT_FOUND");
    }

    #[tokio::test]
    async fn list_dir_hides_dotfiles_by_default() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        let entries = result["entries"].as_array().unwrap();
        for entry in entries {
            let name = entry["name"].as_str().unwrap();
            assert!(!name.starts_with('.'));
        }
    }

    #[tokio::test]
    async fn list_dir_directories_first() {
        let ctx = make_test_context();
        let result = ListDirHandler
            .handle(Some(json!({"path": "/tmp"})), &ctx)
            .await
            .unwrap();
        let entries = result["entries"].as_array().unwrap();
        let mut seen_file = false;
        for entry in entries {
            let is_dir = entry["isDirectory"].as_bool().unwrap_or(false);
            if !is_dir {
                seen_file = true;
            }
            assert!(
                !(seen_file && is_dir),
                "directory appeared after file - not sorted correctly"
            );
        }
    }

    #[tokio::test]
    async fn get_home() {
        let ctx = make_test_context();
        let result = get_home_result(&ctx).await;
        assert!(result["homePath"].is_string());
        assert!(!result["homePath"].as_str().unwrap().is_empty());
        assert!(result["suggestedPaths"].is_array());
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

//! Filesystem RPC group.
//!
//! `filesystem.getHome`, `filesystem.listDir`, and `file.read` are
//! marker-registered in `handlers::mod` and executed by engine-owned generic
//! trigger functions. `filesystem.createDir` remains handler-owned until the
//! write path gets explicit path guardrails and idempotency policy.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::filesystem_service;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// Create a directory (recursive).
///
/// This remains on the legacy path until filesystem writes have a dedicated
/// agent-native path authority model.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::{RpcErrorBody, RpcRequest};
    use serde_json::{Value, json};

    async fn dispatch_filesystem_ok(ctx: &RpcContext, method: &str, params: Value) -> Value {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    async fn dispatch_filesystem_err(
        ctx: &RpcContext,
        method: &str,
        params: Value,
    ) -> RpcErrorBody {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(!response.success, "{method}: {:?}", response.result);
        response.error.unwrap()
    }

    #[tokio::test]
    async fn list_dir_success() {
        let ctx = make_test_context();
        let result =
            dispatch_filesystem_ok(&ctx, "filesystem.listDir", json!({"path": "/tmp"})).await;
        assert!(result["entries"].is_array());
        assert_eq!(result["path"], "/tmp");
        assert!(result["parent"].is_string());
    }

    #[tokio::test]
    async fn list_dir_entries_have_full_fields() {
        let ctx = make_test_context();
        let result =
            dispatch_filesystem_ok(&ctx, "filesystem.listDir", json!({"path": "/tmp"})).await;
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
        let result = dispatch_filesystem_ok(&ctx, "filesystem.listDir", json!({})).await;
        assert!(result["entries"].is_array());
        assert!(result["path"].is_string());
    }

    #[tokio::test]
    async fn list_dir_not_found() {
        let ctx = make_test_context();
        let err = dispatch_filesystem_err(
            &ctx,
            "filesystem.listDir",
            json!({"path": "/nonexistent_dir_xyz_12345"}),
        )
        .await;
        assert_eq!(err.code, "FILE_NOT_FOUND");
    }

    #[tokio::test]
    async fn list_dir_hides_dotfiles_by_default() {
        let ctx = make_test_context();
        let result =
            dispatch_filesystem_ok(&ctx, "filesystem.listDir", json!({"path": "/tmp"})).await;
        for entry in result["entries"].as_array().unwrap() {
            let name = entry["name"].as_str().unwrap();
            assert!(!name.starts_with('.'));
        }
    }

    #[tokio::test]
    async fn list_dir_directories_first() {
        let ctx = make_test_context();
        let result =
            dispatch_filesystem_ok(&ctx, "filesystem.listDir", json!({"path": "/tmp"})).await;
        let mut seen_file = false;
        for entry in result["entries"].as_array().unwrap() {
            let is_dir = entry["isDirectory"].as_bool().unwrap_or(false);
            if !is_dir {
                seen_file = true;
            }
            assert!(!(seen_file && is_dir));
        }
    }

    #[tokio::test]
    async fn get_home() {
        let ctx = make_test_context();
        let result = dispatch_filesystem_ok(&ctx, "filesystem.getHome", json!({})).await;
        assert!(result["homePath"].is_string());
        assert!(!result["homePath"].as_str().unwrap().is_empty());
        assert!(result["suggestedPaths"].is_array());
    }

    #[tokio::test]
    async fn read_file_not_found() {
        let ctx = make_test_context();
        let err = dispatch_filesystem_err(
            &ctx,
            "file.read",
            json!({"path": "/nonexistent_file_xyz_12345.txt"}),
        )
        .await;
        assert_eq!(err.code, "FILE_NOT_FOUND");
    }

    #[tokio::test]
    async fn read_file_missing_param() {
        let ctx = make_test_context();
        let err = dispatch_filesystem_err(&ctx, "file.read", json!({})).await;
        assert_eq!(err.code, "INVALID_PARAMS");
    }
}

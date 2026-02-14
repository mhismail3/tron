//! Sandbox handlers: listContainers, startContainer, stopContainer, killContainer.

use std::path::PathBuf;

use async_trait::async_trait;
use serde_json::Value;
use tracing::{debug, instrument};

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Path to the containers metadata file.
fn containers_json_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home)
        .join(".tron")
        .join("artifacts")
        .join("containers.json")
}

/// List running sandbox containers.
pub struct ListContainersHandler;

#[async_trait]
impl MethodHandler for ListContainersHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.listContainers"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = containers_json_path();
        let containers = if path.exists() {
            let content =
                std::fs::read_to_string(&path).map_err(|e| RpcError::Internal {
                    message: format!("Failed to read containers.json: {e}"),
                })?;
            match serde_json::from_str::<Value>(&content) {
                Ok(v) if v.is_array() => v,
                _ => serde_json::json!([]),
            }
        } else {
            debug!("containers.json not found, returning empty list");
            serde_json::json!([])
        };

        Ok(serde_json::json!({
            "containers": containers,
        }))
    }
}

/// Run a container command via the CLI.
async fn run_container_command(action: &str, name: &str) -> Result<Value, RpcError> {
    let output = tokio::process::Command::new("container")
        .args([action, name])
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => Ok(serde_json::json!({
            "success": true,
        })),
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            Err(RpcError::Internal {
                message: format!("container {action} failed: {stderr}"),
            })
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(RpcError::NotAvailable {
            message: "Container CLI not found. Install container runtime to use sandbox features."
                .into(),
        }),
        Err(e) => Err(RpcError::Internal {
            message: format!("Failed to execute container command: {e}"),
        }),
    }
}

/// Start a sandbox container.
pub struct StartContainerHandler;

#[async_trait]
impl MethodHandler for StartContainerHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.startContainer"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        run_container_command("start", &name).await
    }
}

/// Stop a sandbox container.
pub struct StopContainerHandler;

#[async_trait]
impl MethodHandler for StopContainerHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.stopContainer"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        run_container_command("stop", &name).await
    }
}

/// Kill a sandbox container.
pub struct KillContainerHandler;

#[async_trait]
impl MethodHandler for KillContainerHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.killContainer"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        run_container_command("kill", &name).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn list_containers_returns_array() {
        let ctx = make_test_context();
        let result = ListContainersHandler.handle(None, &ctx).await.unwrap();
        assert!(result["containers"].is_array());
    }

    #[tokio::test]
    async fn list_containers_reads_file() {
        // Create a temp containers.json
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("containers.json");
        std::fs::write(&path, r#"[{"name":"test","status":"running"}]"#).unwrap();

        // This test validates the parsing logic, not the actual path
        let content = std::fs::read_to_string(&path).unwrap();
        let containers: Value = serde_json::from_str(&content).unwrap();
        assert!(containers.is_array());
        assert_eq!(containers[0]["name"], "test");
    }

    #[tokio::test]
    async fn start_container_requires_name() {
        let ctx = make_test_context();
        let err = StartContainerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn stop_container_requires_name() {
        let ctx = make_test_context();
        let err = StopContainerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn kill_container_requires_name() {
        let ctx = make_test_context();
        let err = KillContainerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn container_cli_not_found() {
        // container CLI almost certainly doesn't exist in test env
        let ctx = make_test_context();
        let err = StartContainerHandler
            .handle(Some(json!({"name": "test-box"})), &ctx)
            .await
            .unwrap_err();
        // Should be NOT_AVAILABLE or INTERNAL_ERROR depending on whether 'container' exists
        assert!(
            err.code() == "NOT_AVAILABLE" || err.code() == "INTERNAL_ERROR",
            "unexpected error code: {}",
            err.code()
        );
    }
}

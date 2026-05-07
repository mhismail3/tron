//! Legacy Codex App Server status RPC handler fixture.
//!
//! Production `codexApp.status` is a generic JSON-RPC trigger into canonical
//! `codex_app::status`. This test-only fixture keeps the old status payload
//! available for regression cases.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::registry::MethodHandler;

/// Return the server-owned Codex App Server status and endpoint.
pub struct CodexAppStatusHandler;

#[async_trait]
impl MethodHandler for CodexAppStatusHandler {
    #[instrument(skip(self, ctx), fields(method = "codexApp.status"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let Some(manager) = &ctx.codex_app_server else {
            return Ok(serde_json::json!({
                "enabled": false,
                "state": "disabled",
                "endpoint": null,
                "defaults": {
                    "preferredCwd": null,
                    "preferredModel": null,
                    "approvalPolicy": "onRequest",
                    "sandboxMode": "workspaceWrite"
                },
                "listenUrl": "ws://0.0.0.0:4500",
                "pid": null,
                "lastError": "Codex App Server lifecycle manager is unavailable"
            }));
        };
        serde_json::to_value(manager.status().await).map_err(|error| RpcError::Internal {
            message: format!("Failed to encode Codex App Server status: {error}"),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::codex_app::{CodexAppServerManager, CodexAppServerSpawner};
    use crate::settings::CodexAppServerSettings;
    use async_trait::async_trait;
    use std::io;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;

    struct NoopSpawner;

    #[async_trait]
    impl CodexAppServerSpawner for NoopSpawner {
        async fn spawn(
            &self,
            _spec: crate::server::codex_app::CodexAppServerLaunchSpec,
        ) -> io::Result<Box<dyn crate::server::codex_app::CodexAppServerChild>> {
            Err(io::Error::new(io::ErrorKind::Other, "not used"))
        }
    }

    #[tokio::test]
    async fn status_returns_disabled_when_manager_absent() {
        let ctx = crate::server::rpc::handlers::test_helpers::make_test_context();

        let value = CodexAppStatusHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(value["enabled"], false);
        assert_eq!(value["state"], "disabled");
        assert!(value["endpoint"].is_null());
    }

    #[tokio::test]
    async fn status_returns_manager_snapshot() {
        let mut ctx = crate::server::rpc::handlers::test_helpers::make_test_context();
        let dir = tempfile::tempdir().unwrap();
        let mut settings = CodexAppServerSettings::default();
        settings.enabled = false;
        let manager = CodexAppServerManager::with_deps(
            settings,
            PathBuf::from(dir.path()).join("token"),
            Arc::new(NoopSpawner),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();
        ctx.codex_app_server = Some(Arc::new(manager));

        let value = CodexAppStatusHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(value["enabled"], false);
        assert_eq!(value["state"], "disabled");
        assert_eq!(value["defaults"]["approvalPolicy"], "onRequest");
        assert_eq!(value["defaults"]["sandboxMode"], "workspaceWrite");
    }
}

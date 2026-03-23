//! Stub render UI provider — returned when json-render-server is not installed.

use async_trait::async_trait;
use serde_json::Value;

use crate::tools::errors::ToolError;
use crate::tools::render_ui::provider::RenderUIProvider;
use crate::tools::render_ui::types::{RenderResult, RenderBackendInfo, RenderBackendStatus};

/// Stub provider that returns install instructions for all operations.
pub struct StubProvider;

const INSTALL_MSG: &str =
    "json-render-server not installed. Install with: brew install json-render-server";

#[async_trait]
impl RenderUIProvider for StubProvider {
    fn name(&self) -> &str {
        "stub"
    }

    async fn push_spec(
        &self,
        _canvas_id: &str,
        _spec: &Value,
        _title: Option<&str>,
    ) -> Result<RenderResult, ToolError> {
        Err(ToolError::Internal {
            message: INSTALL_MSG.into(),
        })
    }

    async fn push_chunk(
        &self,
        _canvas_id: &str,
        _chunk: &str,
    ) -> Result<(), ToolError> {
        Err(ToolError::Internal {
            message: INSTALL_MSG.into(),
        })
    }

    async fn complete_render(
        &self,
        _canvas_id: &str,
    ) -> Result<RenderResult, ToolError> {
        Err(ToolError::Internal {
            message: INSTALL_MSG.into(),
        })
    }

    fn canvas_url(&self, _canvas_id: &str) -> Option<String> {
        None
    }

    fn get_status(&self) -> RenderBackendStatus {
        RenderBackendStatus::Stopped
    }

    async fn ensure_running(&self) -> Result<RenderBackendInfo, ToolError> {
        Err(ToolError::Internal {
            message: INSTALL_MSG.into(),
        })
    }

    async fn shutdown(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn stub_push_spec_returns_error() {
        let stub = StubProvider;
        let err = stub.push_spec("c1", &json!({}), None).await;
        assert!(err.is_err());
        let msg = format!("{}", err.unwrap_err());
        assert!(msg.contains("json-render-server not installed"));
    }

    #[tokio::test]
    async fn stub_push_chunk_returns_error() {
        let stub = StubProvider;
        let err = stub.push_chunk("c1", "{}").await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn stub_complete_render_returns_error() {
        let stub = StubProvider;
        let err = stub.complete_render("c1").await;
        assert!(err.is_err());
    }

    #[test]
    fn stub_canvas_url_returns_none() {
        let stub = StubProvider;
        assert!(stub.canvas_url("c1").is_none());
    }

    #[test]
    fn stub_get_status_returns_stopped() {
        let stub = StubProvider;
        match stub.get_status() {
            RenderBackendStatus::Stopped => {}
            other => panic!("expected Stopped, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn stub_ensure_running_returns_error() {
        let stub = StubProvider;
        let err = stub.ensure_running().await;
        assert!(err.is_err());
    }

    #[test]
    fn stub_name_is_stub() {
        let stub = StubProvider;
        assert_eq!(stub.name(), "stub");
    }

    #[tokio::test]
    async fn stub_shutdown_is_noop() {
        let stub = StubProvider;
        stub.shutdown().await;
    }
}

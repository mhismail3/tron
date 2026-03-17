//! Stub browser provider — returned when no real provider is found.

use async_trait::async_trait;
use tokio::sync::broadcast;

use crate::tools::browser::provider::BrowserProvider;
use crate::tools::browser::types::{BrowserEvent, BrowserStatus};
use crate::tools::errors::ToolError;
use crate::tools::traits::{BrowserAction, BrowserResult};

/// Stub provider that returns "not available" for all actions.
pub struct StubProvider;

#[async_trait]
impl BrowserProvider for StubProvider {
    fn name(&self) -> &str {
        "stub"
    }

    async fn execute_action(
        &self,
        _session_id: &str,
        _action: &BrowserAction,
    ) -> Result<BrowserResult, ToolError> {
        Err(ToolError::Internal {
            message: "Browser automation not available — install agent-browser".into(),
        })
    }

    async fn close_session(&self, _session_id: &str) -> Result<(), ToolError> {
        Err(ToolError::Internal {
            message: "Browser automation not available".into(),
        })
    }

    async fn start_stream(&self, _session_id: &str) -> Result<(), ToolError> {
        Err(ToolError::Internal {
            message: "Browser streaming not available".into(),
        })
    }

    async fn stop_stream(&self, _session_id: &str) -> Result<(), ToolError> {
        Ok(())
    }

    fn get_status(&self, _session_id: &str) -> BrowserStatus {
        BrowserStatus::default()
    }

    fn subscribe(&self) -> broadcast::Receiver<BrowserEvent> {
        let (tx, rx) = broadcast::channel(1);
        drop(tx);
        rx
    }

    async fn close_all_sessions(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn stub_execute_returns_error() {
        let stub = StubProvider;
        let action = BrowserAction {
            action: "navigate".into(),
            params: json!({"url": "https://example.com"}),
        };
        let err = stub.execute_action("s1", &action).await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn stub_close_session_returns_error() {
        let stub = StubProvider;
        let err = stub.close_session("s1").await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn stub_start_stream_returns_error() {
        let stub = StubProvider;
        let err = stub.start_stream("s1").await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn stub_stop_stream_is_ok() {
        let stub = StubProvider;
        assert!(stub.stop_stream("s1").await.is_ok());
    }

    #[test]
    fn stub_get_status_returns_defaults() {
        let stub = StubProvider;
        let status = stub.get_status("s1");
        assert!(!status.has_browser);
        assert!(!status.is_streaming);
        assert!(status.current_url.is_none());
    }

    #[test]
    fn stub_subscribe_returns_receiver() {
        let stub = StubProvider;
        let _rx = stub.subscribe();
    }

    #[test]
    fn stub_name_is_stub() {
        let stub = StubProvider;
        assert_eq!(stub.name(), "stub");
    }

    #[tokio::test]
    async fn stub_close_all_is_noop() {
        let stub = StubProvider;
        stub.close_all_sessions().await;
    }
}

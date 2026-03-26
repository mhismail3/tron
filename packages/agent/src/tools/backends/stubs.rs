//! Stub implementations of DI traits for tools whose backends aren't yet wired.
//!
//! These allow ALL tools to be registered in the tool registry (so they appear
//! in the iOS context manager sheet) while gracefully returning "not available"
//! errors at execution time.

use async_trait::async_trait;

use crate::tools::errors::ToolError;
use crate::tools::traits::{
    Notification, NotifyDelegate, NotifyResult, SubagentConfig,
    SubagentHandle, SubagentResult, SubagentSpawner, WaitMode,
};

fn not_available(feature: &str) -> ToolError {
    ToolError::Internal {
        message: format!("{feature} is not yet available on this server"),
    }
}

// ─── SubagentSpawner ─────────────────────────────────────────────────────────

/// Stub subagent spawner — subagent execution isn't wired yet.
pub struct StubSubagentSpawner;

#[async_trait]
impl SubagentSpawner for StubSubagentSpawner {
    async fn spawn(&self, _config: SubagentConfig) -> Result<SubagentHandle, ToolError> {
        Err(not_available("Subagent spawning"))
    }
    async fn wait_for_agents(
        &self,
        _session_ids: &[String],
        _mode: WaitMode,
        _timeout_ms: u64,
    ) -> Result<Vec<SubagentResult>, ToolError> {
        Err(not_available("Subagent waiting"))
    }
}

// ─── NotifyDelegate ──────────────────────────────────────────────────────────

/// Stub notification delegate — APNS push isn't wired yet.
pub struct StubNotifyDelegate;

#[async_trait]
impl NotifyDelegate for StubNotifyDelegate {
    async fn send_notification(
        &self,
        _notification: &Notification,
    ) -> Result<NotifyResult, ToolError> {
        Err(not_available("Push notifications"))
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn stub_subagent_spawner_returns_error() {
        let spawner = StubSubagentSpawner;
        let config = SubagentConfig {
            task: "test".into(),
            mode: crate::tools::traits::SubagentMode::InProcess,
            blocking: false,
            model: None,
            parent_session_id: None,
            system_prompt: None,
            working_directory: "/tmp".into(),
            max_turns: 5,
            timeout_ms: 30_000,
            tool_denials: None,
            skills: None,
            max_depth: 0,
            current_depth: 0,
            tool_call_id: None,
        };
        let err = spawner.spawn(config).await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn stub_notify_delegate_returns_error() {
        let delegate = StubNotifyDelegate;
        let notification = Notification {
            title: "Test".into(),
            body: "Hello".into(),
            priority: "normal".into(),
            badge: None,
            data: None,
            sheet_content: None,
        };
        let err = delegate.send_notification(&notification).await;
        assert!(err.is_err());
    }

}

//! Stub implementations of DI traits for tools whose backends aren't yet wired.
//!
//! These support product-degraded tool capability handlers while gracefully
//! returning "not available" errors at execution time.

use async_trait::async_trait;

use crate::domains::tools::implementations::errors::ToolError;
use crate::domains::tools::implementations::traits::{
    Notification, NotifyDelegate, NotifyResult, SubagentConfig, SubagentHandle, SubagentResult,
    SubagentSpawner, WaitMode,
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

/// Stub notification delegate — no push service configured on this server.
///
/// Returns a non-error `NotifyResult` with `success: false` and a
/// `warning` field explaining the state. Erroring the tool blocks the
/// agent's flow when a user simply hasn't wired push yet; a warning
/// instead lets the agent continue and tell the user "the notification
/// was requested but push isn't configured — here's what to set up".
pub struct StubNotifyDelegate;

/// Message surfaced to the agent when a `NotifyApp` call hits the stub.
/// Extracted as a constant so tests can assert on the exact wording.
pub const STUB_NOTIFY_WARNING: &str = "Push service is not configured on this server. The notification \
     was not delivered to any device. Configure APNs (direct or via \
     relay) in the server settings to enable push notifications.";

#[async_trait]
impl NotifyDelegate for StubNotifyDelegate {
    async fn send_notification(
        &self,
        _notification: &Notification,
    ) -> Result<NotifyResult, ToolError> {
        Ok(NotifyResult {
            success: false,
            message: None,
            success_count: 0,
            total_count: 0,
            warning: Some(STUB_NOTIFY_WARNING.to_string()),
        })
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
            mode: crate::domains::tools::implementations::traits::SubagentMode::InProcess,
            blocking_timeout_ms: None,
            model: None,
            parent_session_id: None,
            system_prompt: None,
            working_directory: "/tmp".into(),
            max_turns: 5,
            timeout_ms: 30_000,
            denied_tools: vec![],
            skills: None,
            max_depth: 0,
            current_depth: 0,
            tool_call_id: None,
        };
        let err = spawner.spawn(config).await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn stub_notify_delegate_returns_warning_not_error() {
        // The stub must NOT error (erroring blocks the agent's flow
        // on an unconfigured-push setup). It returns a well-formed
        // NotifyResult whose `warning` field explains the state so
        // the NotifyApp tool can surface it.
        let delegate = StubNotifyDelegate;
        let notification = Notification {
            title: "Test".into(),
            body: "Hello".into(),
            priority: "normal".into(),
            badge: None,
            data: None,
            sheet_content: None,
        };
        let result = delegate.send_notification(&notification).await.unwrap();
        assert!(!result.success, "nothing was actually delivered");
        assert_eq!(result.success_count, 0);
        assert_eq!(result.total_count, 0);
        let warning = result.warning.expect("stub MUST set warning");
        assert_eq!(warning, STUB_NOTIFY_WARNING);
    }

    #[tokio::test]
    async fn stub_warning_mentions_push_service_configuration() {
        // The exact wording matters — the agent relays it to the user,
        // so "configure APNs" and "relay" need to be in the text.
        assert!(
            STUB_NOTIFY_WARNING.to_lowercase().contains("push"),
            "warning must reference 'push'"
        );
        assert!(
            STUB_NOTIFY_WARNING.to_lowercase().contains("apn"),
            "warning must reference APNs so user knows what to configure"
        );
        assert!(
            STUB_NOTIFY_WARNING.to_lowercase().contains("relay"),
            "warning must mention the relay as an alternative"
        );
    }
}

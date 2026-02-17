//! Stub implementations of DI traits for tools whose backends aren't yet wired.
//!
//! These allow ALL tools to be registered in the tool registry (so they appear
//! in the iOS context manager sheet) while gracefully returning "not available"
//! errors at execution time.

use async_trait::async_trait;
use serde_json::Value;

use crate::errors::ToolError;
use crate::traits::{
    BrowserAction, BrowserDelegate, BrowserResult, EventStoreQuery, MessageBus, MessageFilter,
    MessageSendResult, MemoryEntry, NotifyDelegate, NotifyResult, Notification, OutgoingMessage,
    ReceivedMessage, SessionInfo, SubagentConfig, SubagentHandle, SubagentResult,
    SubagentSpawner, TaskManagerDelegate, WaitMode,
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
    async fn query_agent(
        &self,
        _session_id: &str,
        _query_type: &str,
        _limit: Option<u32>,
    ) -> Result<Value, ToolError> {
        Err(not_available("Subagent queries"))
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

// ─── BrowserDelegate ─────────────────────────────────────────────────────────

/// Stub browser delegate — browser automation isn't wired yet.
pub struct StubBrowserDelegate;

#[async_trait]
impl BrowserDelegate for StubBrowserDelegate {
    async fn execute_action(
        &self,
        _session_id: &str,
        _action: &BrowserAction,
    ) -> Result<BrowserResult, ToolError> {
        Err(not_available("Browser automation"))
    }
    async fn close_session(&self, _session_id: &str) -> Result<(), ToolError> {
        Err(not_available("Browser automation"))
    }
}

// ─── NotifyDelegate ──────────────────────────────────────────────────────────

/// ADAPTER(tool-compat): Fire-and-forget notify delegate for OpenURL.
///
/// OpenURL doesn't need real APNS — it validates the URL and returns success.
/// iOS opens Safari when it receives the tool_execution_start event.
///
/// REMOVE: When OpenURL is refactored to not require a NotifyDelegate.
pub struct NoOpOpenUrlDelegate;

#[async_trait]
impl NotifyDelegate for NoOpOpenUrlDelegate {
    async fn send_notification(
        &self,
        _notification: &Notification,
    ) -> Result<NotifyResult, ToolError> {
        Err(not_available("Push notifications"))
    }
    async fn open_url_in_app(&self, _url: &str) -> Result<(), ToolError> {
        Ok(()) // Fire-and-forget — iOS handles via tool event
    }
}

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
    async fn open_url_in_app(&self, _url: &str) -> Result<(), ToolError> {
        Err(not_available("URL opening"))
    }
}

// ─── MessageBus ──────────────────────────────────────────────────────────────

/// Stub message bus — inter-session messaging isn't wired yet.
pub struct StubMessageBus;

#[async_trait]
impl MessageBus for StubMessageBus {
    async fn send_message(&self, _msg: &OutgoingMessage) -> Result<MessageSendResult, ToolError> {
        Err(not_available("Inter-session messaging"))
    }
    async fn receive_messages(
        &self,
        _session_id: &str,
        _filter: &MessageFilter,
    ) -> Result<Vec<ReceivedMessage>, ToolError> {
        Err(not_available("Inter-session messaging"))
    }
}

// ─── EventStoreQuery ─────────────────────────────────────────────────────────

/// Stub event store query — memory recall isn't wired yet.
pub struct StubEventStoreQuery;

#[async_trait]
impl EventStoreQuery for StubEventStoreQuery {
    async fn recall_memory(
        &self,
        _query: &str,
        _limit: u32,
    ) -> Result<Vec<MemoryEntry>, ToolError> {
        Err(not_available("Memory recall"))
    }
    async fn search_memory(
        &self,
        _session_id: Option<&str>,
        _query: &str,
        _limit: u32,
        _offset: u32,
    ) -> Result<Vec<MemoryEntry>, ToolError> {
        Err(not_available("Memory search"))
    }
    async fn list_sessions(
        &self,
        _limit: u32,
        _offset: u32,
    ) -> Result<Vec<SessionInfo>, ToolError> {
        Err(not_available("Session listing"))
    }
    async fn get_session(&self, _session_id: &str) -> Result<Option<SessionInfo>, ToolError> {
        Err(not_available("Session lookup"))
    }
    async fn get_events(
        &self,
        _session_id: &str,
        _event_type: Option<&str>,
        _turn: Option<u32>,
        _limit: u32,
        _offset: u32,
    ) -> Result<Vec<Value>, ToolError> {
        Err(not_available("Event queries"))
    }
    async fn get_messages(
        &self,
        _session_id: &str,
        _limit: u32,
    ) -> Result<Vec<Value>, ToolError> {
        Err(not_available("Message queries"))
    }
    async fn get_tool_calls(
        &self,
        _session_id: &str,
        _limit: u32,
    ) -> Result<Vec<Value>, ToolError> {
        Err(not_available("Tool call queries"))
    }
    async fn get_logs(
        &self,
        _session_id: &str,
        _level: Option<&str>,
        _limit: u32,
        _offset: u32,
    ) -> Result<Vec<Value>, ToolError> {
        Err(not_available("Log queries"))
    }
    async fn get_stats(&self) -> Result<Value, ToolError> {
        Err(not_available("Database stats"))
    }
    async fn get_schema(&self) -> Result<String, ToolError> {
        Err(not_available("Schema queries"))
    }
    async fn read_blob(&self, _blob_id: &str) -> Result<String, ToolError> {
        Err(not_available("Blob storage"))
    }
}

// ─── TaskManagerDelegate ─────────────────────────────────────────────────────

/// Stub task manager — task execution isn't wired yet.
pub struct StubTaskManagerDelegate;

#[async_trait]
impl TaskManagerDelegate for StubTaskManagerDelegate {
    async fn execute_action(&self, _action: &str, _params: Value) -> Result<Value, ToolError> {
        Err(not_available("Task management"))
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
            mode: crate::traits::SubagentMode::InProcess,
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
    async fn stub_browser_delegate_returns_error() {
        let delegate = StubBrowserDelegate;
        let action = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "https://example.com"}),
        };
        let err = delegate.execute_action("s1", &action).await;
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

    #[tokio::test]
    async fn stub_message_bus_returns_error() {
        let bus = StubMessageBus;
        let msg = OutgoingMessage {
            target_session_id: "s2".into(),
            message_type: "test".into(),
            payload: serde_json::json!({}),
            wait_for_reply: false,
            timeout_ms: 5000,
        };
        let err = bus.send_message(&msg).await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn stub_event_store_query_returns_error() {
        let store = StubEventStoreQuery;
        let err = store.recall_memory("test query", 10).await;
        assert!(err.is_err());
    }

    #[tokio::test]
    async fn stub_task_manager_returns_error() {
        let delegate = StubTaskManagerDelegate;
        let err = delegate
            .execute_action("create", serde_json::json!({"title": "test"}))
            .await;
        assert!(err.is_err());
    }
}

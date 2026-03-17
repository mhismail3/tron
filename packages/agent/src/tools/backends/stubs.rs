//! Stub implementations of DI traits for tools whose backends aren't yet wired.
//!
//! These allow ALL tools to be registered in the tool registry (so they appear
//! in the iOS context manager sheet) while gracefully returning "not available"
//! errors at execution time.

use async_trait::async_trait;
use serde_json::Value;

use crate::tools::errors::ToolError;
use crate::tools::traits::{
    EventStoreQuery, MemoryEntry,
    Notification, NotifyDelegate, NotifyResult, SessionInfo, SubagentConfig,
    SubagentHandle, SubagentResult, SubagentSpawner, TaskManagerDelegate, WaitMode,
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

// ─── EventStoreQuery ─────────────────────────────────────────────────────────

/// Stub event store query — memory recall isn't wired yet.
pub struct StubEventStoreQuery;

#[async_trait]
impl EventStoreQuery for StubEventStoreQuery {
    async fn recall_memory(
        &self,
        _query: &str,
        _workspace_id: Option<&str>,
        _limit: u32,
    ) -> Result<Vec<MemoryEntry>, ToolError> {
        Err(not_available("Memory recall"))
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
    async fn get_messages(&self, _session_id: &str, _limit: u32) -> Result<Vec<Value>, ToolError> {
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

    #[tokio::test]
    async fn stub_event_store_query_returns_error() {
        let store = StubEventStoreQuery;
        let err = store.recall_memory("test query", None, 10).await;
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

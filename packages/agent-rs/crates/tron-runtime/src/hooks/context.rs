//! Hook context factory.
//!
//! Provides a trait and default implementation for creating typed
//! [`HookContext`] instances. The factory automatically populates session ID
//! and timestamps, so callers only need to provide event-specific data.

use chrono::Utc;

use super::types::HookContext;

/// Factory for creating [`HookContext`] instances.
///
/// Implementations are scoped to a session — the `session_id` is set once
/// and used for all created contexts. Timestamps are generated automatically.
pub trait HookContextFactory: Send + Sync {
    /// Create a [`HookContext::PreToolUse`] context.
    fn create_pre_tool_context(
        &self,
        tool_name: &str,
        arguments: serde_json::Value,
        tool_call_id: &str,
    ) -> HookContext;

    /// Create a [`HookContext::PostToolUse`] context.
    fn create_post_tool_context(
        &self,
        tool_name: &str,
        tool_call_id: &str,
        result: serde_json::Value,
        duration_ms: u64,
    ) -> HookContext;

    /// Create a [`HookContext::Stop`] context.
    fn create_stop_context(
        &self,
        stop_reason: &str,
        final_message: Option<&str>,
    ) -> HookContext;

    /// Create a [`HookContext::SessionStart`] context.
    fn create_session_start_context(
        &self,
        working_directory: &str,
        parent_handoff_id: Option<&str>,
    ) -> HookContext;

    /// Create a [`HookContext::SessionEnd`] context.
    fn create_session_end_context(
        &self,
        message_count: u64,
        tool_call_count: u64,
    ) -> HookContext;

    /// Create a [`HookContext::UserPromptSubmit`] context.
    fn create_user_prompt_submit_context(&self, prompt: &str) -> HookContext;

    /// Create a [`HookContext::SubagentStop`] context.
    fn create_subagent_stop_context(
        &self,
        subagent_id: &str,
        stop_reason: &str,
        result: Option<serde_json::Value>,
    ) -> HookContext;

    /// Create a [`HookContext::PreCompact`] context.
    fn create_pre_compact_context(
        &self,
        current_tokens: u64,
        target_tokens: u64,
    ) -> HookContext;

    /// Create a [`HookContext::Notification`] context.
    fn create_notification_context(
        &self,
        level: &str,
        title: &str,
        body: Option<&str>,
    ) -> HookContext;
}

/// Default implementation of [`HookContextFactory`].
///
/// Scoped to a single session. Timestamps use UTC ISO 8601 format.
#[derive(Debug, Clone)]
pub struct DefaultContextFactory {
    session_id: String,
}

impl DefaultContextFactory {
    /// Create a new factory scoped to a session.
    #[must_use]
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
        }
    }

    fn now() -> String {
        Utc::now().to_rfc3339()
    }
}

impl HookContextFactory for DefaultContextFactory {
    fn create_pre_tool_context(
        &self,
        tool_name: &str,
        arguments: serde_json::Value,
        tool_call_id: &str,
    ) -> HookContext {
        HookContext::PreToolUse {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            tool_name: tool_name.to_string(),
            tool_arguments: arguments,
            tool_call_id: tool_call_id.to_string(),
        }
    }

    fn create_post_tool_context(
        &self,
        tool_name: &str,
        tool_call_id: &str,
        result: serde_json::Value,
        duration_ms: u64,
    ) -> HookContext {
        HookContext::PostToolUse {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            tool_name: tool_name.to_string(),
            tool_call_id: tool_call_id.to_string(),
            result,
            duration_ms,
        }
    }

    fn create_stop_context(
        &self,
        stop_reason: &str,
        final_message: Option<&str>,
    ) -> HookContext {
        HookContext::Stop {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            stop_reason: stop_reason.to_string(),
            final_message: final_message.map(ToString::to_string),
        }
    }

    fn create_session_start_context(
        &self,
        working_directory: &str,
        parent_handoff_id: Option<&str>,
    ) -> HookContext {
        HookContext::SessionStart {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            working_directory: working_directory.to_string(),
            parent_handoff_id: parent_handoff_id.map(ToString::to_string),
        }
    }

    fn create_session_end_context(
        &self,
        message_count: u64,
        tool_call_count: u64,
    ) -> HookContext {
        HookContext::SessionEnd {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            message_count,
            tool_call_count,
        }
    }

    fn create_user_prompt_submit_context(&self, prompt: &str) -> HookContext {
        HookContext::UserPromptSubmit {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            prompt: prompt.to_string(),
        }
    }

    fn create_subagent_stop_context(
        &self,
        subagent_id: &str,
        stop_reason: &str,
        result: Option<serde_json::Value>,
    ) -> HookContext {
        HookContext::SubagentStop {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            subagent_id: subagent_id.to_string(),
            stop_reason: stop_reason.to_string(),
            result,
        }
    }

    fn create_pre_compact_context(
        &self,
        current_tokens: u64,
        target_tokens: u64,
    ) -> HookContext {
        HookContext::PreCompact {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            current_tokens,
            target_tokens,
        }
    }

    fn create_notification_context(
        &self,
        level: &str,
        title: &str,
        body: Option<&str>,
    ) -> HookContext {
        HookContext::Notification {
            session_id: self.session_id.clone(),
            timestamp: Self::now(),
            level: level.to_string(),
            title: title.to_string(),
            body: body.map(ToString::to_string),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hooks::types::HookType;

    fn make_factory() -> DefaultContextFactory {
        DefaultContextFactory::new("session-123")
    }

    #[test]
    fn test_pre_tool_context() {
        let factory = make_factory();
        let ctx = factory.create_pre_tool_context(
            "Bash",
            serde_json::json!({"command": "ls"}),
            "tc-1",
        );
        assert_eq!(ctx.hook_type(), HookType::PreToolUse);
        assert_eq!(ctx.session_id(), "session-123");
        assert!(!ctx.timestamp().is_empty());
    }

    #[test]
    fn test_post_tool_context() {
        let factory = make_factory();
        let ctx = factory.create_post_tool_context(
            "Bash",
            "tc-1",
            serde_json::json!({"output": "foo"}),
            150,
        );
        assert_eq!(ctx.hook_type(), HookType::PostToolUse);
        assert_eq!(ctx.session_id(), "session-123");
    }

    #[test]
    fn test_stop_context() {
        let factory = make_factory();
        let ctx = factory.create_stop_context("end_turn", Some("Done."));
        assert_eq!(ctx.hook_type(), HookType::Stop);
        if let HookContext::Stop { final_message, .. } = &ctx {
            assert_eq!(final_message.as_deref(), Some("Done."));
        } else {
            panic!("Expected Stop context");
        }
    }

    #[test]
    fn test_stop_context_no_message() {
        let factory = make_factory();
        let ctx = factory.create_stop_context("end_turn", None);
        if let HookContext::Stop { final_message, .. } = &ctx {
            assert!(final_message.is_none());
        } else {
            panic!("Expected Stop context");
        }
    }

    #[test]
    fn test_session_start_context() {
        let factory = make_factory();
        let ctx = factory.create_session_start_context("/tmp/project", None);
        assert_eq!(ctx.hook_type(), HookType::SessionStart);
        if let HookContext::SessionStart {
            working_directory,
            parent_handoff_id,
            ..
        } = &ctx
        {
            assert_eq!(working_directory, "/tmp/project");
            assert!(parent_handoff_id.is_none());
        } else {
            panic!("Expected SessionStart context");
        }
    }

    #[test]
    fn test_session_start_with_handoff() {
        let factory = make_factory();
        let ctx = factory.create_session_start_context("/tmp", Some("parent-1"));
        if let HookContext::SessionStart {
            parent_handoff_id, ..
        } = &ctx
        {
            assert_eq!(parent_handoff_id.as_deref(), Some("parent-1"));
        } else {
            panic!("Expected SessionStart context");
        }
    }

    #[test]
    fn test_session_end_context() {
        let factory = make_factory();
        let ctx = factory.create_session_end_context(10, 5);
        assert_eq!(ctx.hook_type(), HookType::SessionEnd);
        if let HookContext::SessionEnd {
            message_count,
            tool_call_count,
            ..
        } = &ctx
        {
            assert_eq!(*message_count, 10);
            assert_eq!(*tool_call_count, 5);
        } else {
            panic!("Expected SessionEnd context");
        }
    }

    #[test]
    fn test_user_prompt_submit_context() {
        let factory = make_factory();
        let ctx = factory.create_user_prompt_submit_context("Hello, world!");
        assert_eq!(ctx.hook_type(), HookType::UserPromptSubmit);
        if let HookContext::UserPromptSubmit { prompt, .. } = &ctx {
            assert_eq!(prompt, "Hello, world!");
        } else {
            panic!("Expected UserPromptSubmit context");
        }
    }

    #[test]
    fn test_subagent_stop_context() {
        let factory = make_factory();
        let ctx = factory.create_subagent_stop_context("sub-1", "done", None);
        assert_eq!(ctx.hook_type(), HookType::SubagentStop);
    }

    #[test]
    fn test_pre_compact_context() {
        let factory = make_factory();
        let ctx = factory.create_pre_compact_context(50000, 30000);
        assert_eq!(ctx.hook_type(), HookType::PreCompact);
        if let HookContext::PreCompact {
            current_tokens,
            target_tokens,
            ..
        } = &ctx
        {
            assert_eq!(*current_tokens, 50000);
            assert_eq!(*target_tokens, 30000);
        } else {
            panic!("Expected PreCompact context");
        }
    }

    #[test]
    fn test_notification_context() {
        let factory = make_factory();
        let ctx = factory.create_notification_context("info", "Update", Some("Details here"));
        assert_eq!(ctx.hook_type(), HookType::Notification);
        if let HookContext::Notification {
            level, title, body, ..
        } = &ctx
        {
            assert_eq!(level, "info");
            assert_eq!(title, "Update");
            assert_eq!(body.as_deref(), Some("Details here"));
        } else {
            panic!("Expected Notification context");
        }
    }

    #[test]
    fn test_notification_context_no_body() {
        let factory = make_factory();
        let ctx = factory.create_notification_context("error", "Fail", None);
        if let HookContext::Notification { body, .. } = &ctx {
            assert!(body.is_none());
        } else {
            panic!("Expected Notification context");
        }
    }

    #[test]
    fn test_factory_session_id_consistent() {
        let factory = make_factory();
        let c1 = factory.create_stop_context("a", None);
        let c2 = factory.create_pre_compact_context(100, 50);
        assert_eq!(c1.session_id(), c2.session_id());
        assert_eq!(c1.session_id(), "session-123");
    }
}

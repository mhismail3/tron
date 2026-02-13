//! Type guard functions for [`SessionEvent`](super::base::SessionEvent).
//!
//! These replace TypeScript `isXxxEvent()` type guards. In Rust, you'd
//! normally pattern-match on `event.event_type`, but these functions are
//! convenient for filtering event collections.

use super::base::SessionEvent;
use super::event_type::EventType;

/// Whether the event is a message event (`message.user|assistant|system`).
#[must_use]
pub fn is_message_event(event: &SessionEvent) -> bool {
    event.event_type.is_message_type()
}

/// Whether the event is a streaming event (`stream.*`).
#[must_use]
pub fn is_streaming_event(event: &SessionEvent) -> bool {
    event.event_type.is_streaming_type()
}

/// Whether the event is an error event (`error.*`).
#[must_use]
pub fn is_error_event(event: &SessionEvent) -> bool {
    event.event_type.is_error_type()
}

/// Whether the event is a config event (`config.*`).
#[must_use]
pub fn is_config_event(event: &SessionEvent) -> bool {
    event.event_type.is_config_type()
}

/// Whether the event is a worktree event (`worktree.*`).
#[must_use]
pub fn is_worktree_event(event: &SessionEvent) -> bool {
    event.event_type.is_worktree_type()
}

/// Whether the event is a subagent event (`subagent.*`).
#[must_use]
pub fn is_subagent_event(event: &SessionEvent) -> bool {
    event.event_type.is_subagent_type()
}

/// Whether the event is a hook event (`hook.*`).
#[must_use]
pub fn is_hook_event(event: &SessionEvent) -> bool {
    event.event_type.is_hook_type()
}

/// Whether the event is a skill event (`skill.*`).
#[must_use]
pub fn is_skill_event(event: &SessionEvent) -> bool {
    event.event_type.is_skill_type()
}

/// Whether the event is a rules event (`rules.*`).
#[must_use]
pub fn is_rules_event(event: &SessionEvent) -> bool {
    event.event_type.is_rules_type()
}

/// Whether the event is a memory event (`memory.*`).
#[must_use]
pub fn is_memory_event(event: &SessionEvent) -> bool {
    event.event_type.is_memory_type()
}

/// Whether the event is a user message.
#[must_use]
pub fn is_user_message_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::MessageUser
}

/// Whether the event is an assistant message.
#[must_use]
pub fn is_assistant_message_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::MessageAssistant
}

/// Whether the event is a tool call.
#[must_use]
pub fn is_tool_call_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::ToolCall
}

/// Whether the event is a tool result.
#[must_use]
pub fn is_tool_result_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::ToolResult
}

/// Whether the event is a message deletion.
#[must_use]
pub fn is_message_deleted_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::MessageDeleted
}

/// Whether the event is a compact boundary.
#[must_use]
pub fn is_compact_boundary_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::CompactBoundary
}

/// Whether the event is a compact summary.
#[must_use]
pub fn is_compact_summary_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::CompactSummary
}

/// Whether the event is context cleared.
#[must_use]
pub fn is_context_cleared_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::ContextCleared
}

/// Whether the event is a session start.
#[must_use]
pub fn is_session_start_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::SessionStart
}

/// Whether the event is a reasoning level config change.
#[must_use]
pub fn is_config_reasoning_level_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::ConfigReasoningLevel
}

/// Whether the event is a prompt update config change.
#[must_use]
pub fn is_config_prompt_update_event(event: &SessionEvent) -> bool {
    event.event_type == EventType::ConfigPromptUpdate
}

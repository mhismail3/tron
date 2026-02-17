//! The [`EventType`] enum — all 59 session event type discriminators.
//!
//! Every variant has an exact `#[serde(rename)]` matching the TypeScript
//! string literal (e.g., `"session.start"`). This ensures wire-format
//! compatibility with iOS and the WebSocket protocol.
//!
//! Domain helper methods like [`EventType::is_message_type()`] replace
//! TypeScript type guards with compile-time exhaustiveness.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

/// All session event types.
///
/// The 59 variants cover every persisted event in the Tron event sourcing
/// system. Each variant serializes to the exact dot-separated string that
/// iOS and the WebSocket protocol expect.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EventType {
    // -- Session lifecycle --
    /// New session started.
    #[serde(rename = "session.start")]
    SessionStart,
    /// Session ended.
    #[serde(rename = "session.end")]
    SessionEnd,
    /// Session forked from another.
    #[serde(rename = "session.fork")]
    SessionFork,

    // -- Messages --
    /// User message.
    #[serde(rename = "message.user")]
    MessageUser,
    /// Assistant (model) message.
    #[serde(rename = "message.assistant")]
    MessageAssistant,
    /// System-injected message.
    #[serde(rename = "message.system")]
    MessageSystem,
    /// Message deleted (soft delete).
    #[serde(rename = "message.deleted")]
    MessageDeleted,

    // -- Tools --
    /// Tool call from the model.
    #[serde(rename = "tool.call")]
    ToolCall,
    /// Tool execution result.
    #[serde(rename = "tool.result")]
    ToolResult,

    // -- Streaming --
    /// Text delta during streaming.
    #[serde(rename = "stream.text_delta")]
    StreamTextDelta,
    /// Thinking delta during streaming.
    #[serde(rename = "stream.thinking_delta")]
    StreamThinkingDelta,
    /// Turn started streaming.
    #[serde(rename = "stream.turn_start")]
    StreamTurnStart,
    /// Turn finished streaming.
    #[serde(rename = "stream.turn_end")]
    StreamTurnEnd,

    // -- Config --
    /// Model switched.
    #[serde(rename = "config.model_switch")]
    ConfigModelSwitch,
    /// System prompt updated.
    #[serde(rename = "config.prompt_update")]
    ConfigPromptUpdate,
    /// Reasoning level changed.
    #[serde(rename = "config.reasoning_level")]
    ConfigReasoningLevel,

    // -- Notifications --
    /// Agent interrupted by user.
    #[serde(rename = "notification.interrupted")]
    NotificationInterrupted,
    /// Subagent result notification.
    #[serde(rename = "notification.subagent_result")]
    NotificationSubagentResult,

    // -- Compaction --
    /// Compaction boundary marker.
    #[serde(rename = "compact.boundary")]
    CompactBoundary,
    /// Compaction summary.
    #[serde(rename = "compact.summary")]
    CompactSummary,

    // -- Context --
    /// Context cleared.
    #[serde(rename = "context.cleared")]
    ContextCleared,

    // -- Skills --
    /// Skill added to session.
    #[serde(rename = "skill.added")]
    SkillAdded,
    /// Skill removed from session.
    #[serde(rename = "skill.removed")]
    SkillRemoved,

    // -- Rules --
    /// Rules files loaded.
    #[serde(rename = "rules.loaded")]
    RulesLoaded,
    /// Rules indexed.
    #[serde(rename = "rules.indexed")]
    RulesIndexed,

    // -- Metadata --
    /// Session metadata updated.
    #[serde(rename = "metadata.update")]
    MetadataUpdate,
    /// Session tag added/removed.
    #[serde(rename = "metadata.tag")]
    MetadataTag,

    // -- Files --
    /// File read by agent.
    #[serde(rename = "file.read")]
    FileRead,
    /// File written by agent.
    #[serde(rename = "file.write")]
    FileWrite,
    /// File edited by agent.
    #[serde(rename = "file.edit")]
    FileEdit,

    // -- Worktree --
    /// Git worktree acquired.
    #[serde(rename = "worktree.acquired")]
    WorktreeAcquired,
    /// Commit in worktree.
    #[serde(rename = "worktree.commit")]
    WorktreeCommit,
    /// Worktree released.
    #[serde(rename = "worktree.released")]
    WorktreeReleased,
    /// Worktree merged back.
    #[serde(rename = "worktree.merged")]
    WorktreeMerged,

    // -- Errors --
    /// Agent-level error.
    #[serde(rename = "error.agent")]
    ErrorAgent,
    /// Tool execution error.
    #[serde(rename = "error.tool")]
    ErrorTool,
    /// Provider (LLM) error.
    #[serde(rename = "error.provider")]
    ErrorProvider,

    // -- Subagents --
    /// Subagent spawned.
    #[serde(rename = "subagent.spawned")]
    SubagentSpawned,
    /// Subagent status update.
    #[serde(rename = "subagent.status_update")]
    SubagentStatusUpdate,
    /// Subagent completed.
    #[serde(rename = "subagent.completed")]
    SubagentCompleted,
    /// Subagent failed.
    #[serde(rename = "subagent.failed")]
    SubagentFailed,
    /// Subagent results consumed by parent agent.
    #[serde(rename = "subagent.results_consumed")]
    SubagentResultsConsumed,

    // -- Todo --
    /// Todo list written.
    #[serde(rename = "todo.write")]
    TodoWrite,

    // -- Tasks --
    /// Task created.
    #[serde(rename = "task.created")]
    TaskCreated,
    /// Task updated.
    #[serde(rename = "task.updated")]
    TaskUpdated,
    /// Task deleted.
    #[serde(rename = "task.deleted")]
    TaskDeleted,

    // -- Projects --
    /// Project created.
    #[serde(rename = "project.created")]
    ProjectCreated,
    /// Project updated.
    #[serde(rename = "project.updated")]
    ProjectUpdated,
    /// Project deleted.
    #[serde(rename = "project.deleted")]
    ProjectDeleted,

    // -- Areas --
    /// Area created.
    #[serde(rename = "area.created")]
    AreaCreated,
    /// Area updated.
    #[serde(rename = "area.updated")]
    AreaUpdated,
    /// Area deleted.
    #[serde(rename = "area.deleted")]
    AreaDeleted,

    // -- Turn --
    /// Turn failed.
    #[serde(rename = "turn.failed")]
    TurnFailed,

    // -- Hooks --
    /// Hook triggered.
    #[serde(rename = "hook.triggered")]
    HookTriggered,
    /// Hook completed.
    #[serde(rename = "hook.completed")]
    HookCompleted,
    /// Background hook started.
    #[serde(rename = "hook.background_started")]
    HookBackgroundStarted,
    /// Background hook completed.
    #[serde(rename = "hook.background_completed")]
    HookBackgroundCompleted,

    // -- Memory --
    /// Memory ledger entry.
    #[serde(rename = "memory.ledger")]
    MemoryLedger,
    /// Memory loaded into context.
    #[serde(rename = "memory.loaded")]
    MemoryLoaded,
}

/// All event type variants in definition order.
///
/// Useful for iteration in tests and manifest generation.
pub const ALL_EVENT_TYPES: [EventType; 59] = [
    EventType::SessionStart,
    EventType::SessionEnd,
    EventType::SessionFork,
    EventType::MessageUser,
    EventType::MessageAssistant,
    EventType::MessageSystem,
    EventType::MessageDeleted,
    EventType::ToolCall,
    EventType::ToolResult,
    EventType::StreamTextDelta,
    EventType::StreamThinkingDelta,
    EventType::StreamTurnStart,
    EventType::StreamTurnEnd,
    EventType::ConfigModelSwitch,
    EventType::ConfigPromptUpdate,
    EventType::ConfigReasoningLevel,
    EventType::NotificationInterrupted,
    EventType::NotificationSubagentResult,
    EventType::CompactBoundary,
    EventType::CompactSummary,
    EventType::ContextCleared,
    EventType::SkillAdded,
    EventType::SkillRemoved,
    EventType::RulesLoaded,
    EventType::RulesIndexed,
    EventType::MetadataUpdate,
    EventType::MetadataTag,
    EventType::FileRead,
    EventType::FileWrite,
    EventType::FileEdit,
    EventType::WorktreeAcquired,
    EventType::WorktreeCommit,
    EventType::WorktreeReleased,
    EventType::WorktreeMerged,
    EventType::ErrorAgent,
    EventType::ErrorTool,
    EventType::ErrorProvider,
    EventType::SubagentSpawned,
    EventType::SubagentStatusUpdate,
    EventType::SubagentCompleted,
    EventType::SubagentFailed,
    EventType::SubagentResultsConsumed,
    EventType::TodoWrite,
    EventType::TaskCreated,
    EventType::TaskUpdated,
    EventType::TaskDeleted,
    EventType::ProjectCreated,
    EventType::ProjectUpdated,
    EventType::ProjectDeleted,
    EventType::AreaCreated,
    EventType::AreaUpdated,
    EventType::AreaDeleted,
    EventType::TurnFailed,
    EventType::HookTriggered,
    EventType::HookCompleted,
    EventType::HookBackgroundStarted,
    EventType::HookBackgroundCompleted,
    EventType::MemoryLedger,
    EventType::MemoryLoaded,
];

impl EventType {
    /// Return the canonical string representation (e.g., `"session.start"`).
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SessionStart => "session.start",
            Self::SessionEnd => "session.end",
            Self::SessionFork => "session.fork",
            Self::MessageUser => "message.user",
            Self::MessageAssistant => "message.assistant",
            Self::MessageSystem => "message.system",
            Self::MessageDeleted => "message.deleted",
            Self::ToolCall => "tool.call",
            Self::ToolResult => "tool.result",
            Self::StreamTextDelta => "stream.text_delta",
            Self::StreamThinkingDelta => "stream.thinking_delta",
            Self::StreamTurnStart => "stream.turn_start",
            Self::StreamTurnEnd => "stream.turn_end",
            Self::ConfigModelSwitch => "config.model_switch",
            Self::ConfigPromptUpdate => "config.prompt_update",
            Self::ConfigReasoningLevel => "config.reasoning_level",
            Self::NotificationInterrupted => "notification.interrupted",
            Self::NotificationSubagentResult => "notification.subagent_result",
            Self::CompactBoundary => "compact.boundary",
            Self::CompactSummary => "compact.summary",
            Self::ContextCleared => "context.cleared",
            Self::SkillAdded => "skill.added",
            Self::SkillRemoved => "skill.removed",
            Self::RulesLoaded => "rules.loaded",
            Self::RulesIndexed => "rules.indexed",
            Self::MetadataUpdate => "metadata.update",
            Self::MetadataTag => "metadata.tag",
            Self::FileRead => "file.read",
            Self::FileWrite => "file.write",
            Self::FileEdit => "file.edit",
            Self::WorktreeAcquired => "worktree.acquired",
            Self::WorktreeCommit => "worktree.commit",
            Self::WorktreeReleased => "worktree.released",
            Self::WorktreeMerged => "worktree.merged",
            Self::ErrorAgent => "error.agent",
            Self::ErrorTool => "error.tool",
            Self::ErrorProvider => "error.provider",
            Self::SubagentSpawned => "subagent.spawned",
            Self::SubagentStatusUpdate => "subagent.status_update",
            Self::SubagentCompleted => "subagent.completed",
            Self::SubagentFailed => "subagent.failed",
            Self::SubagentResultsConsumed => "subagent.results_consumed",
            Self::TodoWrite => "todo.write",
            Self::TaskCreated => "task.created",
            Self::TaskUpdated => "task.updated",
            Self::TaskDeleted => "task.deleted",
            Self::ProjectCreated => "project.created",
            Self::ProjectUpdated => "project.updated",
            Self::ProjectDeleted => "project.deleted",
            Self::AreaCreated => "area.created",
            Self::AreaUpdated => "area.updated",
            Self::AreaDeleted => "area.deleted",
            Self::TurnFailed => "turn.failed",
            Self::HookTriggered => "hook.triggered",
            Self::HookCompleted => "hook.completed",
            Self::HookBackgroundStarted => "hook.background_started",
            Self::HookBackgroundCompleted => "hook.background_completed",
            Self::MemoryLedger => "memory.ledger",
            Self::MemoryLoaded => "memory.loaded",
        }
    }

    /// Whether this is a message event (`message.*`).
    #[must_use]
    pub fn is_message_type(self) -> bool {
        matches!(
            self,
            Self::MessageUser | Self::MessageAssistant | Self::MessageSystem
        )
    }

    /// Whether this is a streaming event (`stream.*`).
    #[must_use]
    pub fn is_streaming_type(self) -> bool {
        matches!(
            self,
            Self::StreamTextDelta
                | Self::StreamThinkingDelta
                | Self::StreamTurnStart
                | Self::StreamTurnEnd
        )
    }

    /// Whether this is an error event (`error.*`).
    #[must_use]
    pub fn is_error_type(self) -> bool {
        matches!(self, Self::ErrorAgent | Self::ErrorTool | Self::ErrorProvider)
    }

    /// Whether this is a config event (`config.*`).
    #[must_use]
    pub fn is_config_type(self) -> bool {
        matches!(
            self,
            Self::ConfigModelSwitch | Self::ConfigPromptUpdate | Self::ConfigReasoningLevel
        )
    }

    /// Whether this is a worktree event (`worktree.*`).
    #[must_use]
    pub fn is_worktree_type(self) -> bool {
        matches!(
            self,
            Self::WorktreeAcquired
                | Self::WorktreeCommit
                | Self::WorktreeReleased
                | Self::WorktreeMerged
        )
    }

    /// Whether this is a subagent event (`subagent.*`).
    #[must_use]
    pub fn is_subagent_type(self) -> bool {
        matches!(
            self,
            Self::SubagentSpawned
                | Self::SubagentStatusUpdate
                | Self::SubagentCompleted
                | Self::SubagentFailed
                | Self::SubagentResultsConsumed
        )
    }

    /// Whether this is a hook event (`hook.*`).
    #[must_use]
    pub fn is_hook_type(self) -> bool {
        matches!(
            self,
            Self::HookTriggered
                | Self::HookCompleted
                | Self::HookBackgroundStarted
                | Self::HookBackgroundCompleted
        )
    }

    /// Whether this is a skill event (`skill.*`).
    #[must_use]
    pub fn is_skill_type(self) -> bool {
        matches!(self, Self::SkillAdded | Self::SkillRemoved)
    }

    /// Whether this is a rules event (`rules.*`).
    #[must_use]
    pub fn is_rules_type(self) -> bool {
        matches!(self, Self::RulesLoaded | Self::RulesIndexed)
    }

    /// Whether this is a memory event (`memory.*`).
    #[must_use]
    pub fn is_memory_type(self) -> bool {
        matches!(self, Self::MemoryLedger | Self::MemoryLoaded)
    }

    /// Whether this is a task/project/area CRUD event (broadcast-only, not sourced).
    #[must_use]
    pub fn is_task_crud_type(self) -> bool {
        matches!(
            self,
            Self::TaskCreated
                | Self::TaskUpdated
                | Self::TaskDeleted
                | Self::ProjectCreated
                | Self::ProjectUpdated
                | Self::ProjectDeleted
                | Self::AreaCreated
                | Self::AreaUpdated
                | Self::AreaDeleted
        )
    }

    /// Whether this is a session lifecycle event (`session.*`).
    #[must_use]
    pub fn is_session_type(self) -> bool {
        matches!(
            self,
            Self::SessionStart | Self::SessionEnd | Self::SessionFork
        )
    }

    /// Whether this is a file event (`file.*`).
    #[must_use]
    pub fn is_file_type(self) -> bool {
        matches!(self, Self::FileRead | Self::FileWrite | Self::FileEdit)
    }

    /// The domain prefix (e.g., `"session"`, `"message"`, `"tool"`).
    #[must_use]
    pub fn domain(self) -> &'static str {
        let s = self.as_str();
        s.split('.').next().unwrap_or(s)
    }
}

impl fmt::Display for EventType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for EventType {
    type Err = String;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        // Use serde to parse — the `#[serde(rename)]` attributes are the source of truth.
        serde_json::from_value(serde_json::Value::String(s.to_owned()))
            .map_err(|_| format!("unknown event type: {s}"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Canonical mapping: (variant, expected string).
    const EXPECTED: [(EventType, &str); 59] = [
        (EventType::SessionStart, "session.start"),
        (EventType::SessionEnd, "session.end"),
        (EventType::SessionFork, "session.fork"),
        (EventType::MessageUser, "message.user"),
        (EventType::MessageAssistant, "message.assistant"),
        (EventType::MessageSystem, "message.system"),
        (EventType::MessageDeleted, "message.deleted"),
        (EventType::ToolCall, "tool.call"),
        (EventType::ToolResult, "tool.result"),
        (EventType::StreamTextDelta, "stream.text_delta"),
        (EventType::StreamThinkingDelta, "stream.thinking_delta"),
        (EventType::StreamTurnStart, "stream.turn_start"),
        (EventType::StreamTurnEnd, "stream.turn_end"),
        (EventType::ConfigModelSwitch, "config.model_switch"),
        (EventType::ConfigPromptUpdate, "config.prompt_update"),
        (EventType::ConfigReasoningLevel, "config.reasoning_level"),
        (EventType::NotificationInterrupted, "notification.interrupted"),
        (EventType::NotificationSubagentResult, "notification.subagent_result"),
        (EventType::CompactBoundary, "compact.boundary"),
        (EventType::CompactSummary, "compact.summary"),
        (EventType::ContextCleared, "context.cleared"),
        (EventType::SkillAdded, "skill.added"),
        (EventType::SkillRemoved, "skill.removed"),
        (EventType::RulesLoaded, "rules.loaded"),
        (EventType::RulesIndexed, "rules.indexed"),
        (EventType::MetadataUpdate, "metadata.update"),
        (EventType::MetadataTag, "metadata.tag"),
        (EventType::FileRead, "file.read"),
        (EventType::FileWrite, "file.write"),
        (EventType::FileEdit, "file.edit"),
        (EventType::WorktreeAcquired, "worktree.acquired"),
        (EventType::WorktreeCommit, "worktree.commit"),
        (EventType::WorktreeReleased, "worktree.released"),
        (EventType::WorktreeMerged, "worktree.merged"),
        (EventType::ErrorAgent, "error.agent"),
        (EventType::ErrorTool, "error.tool"),
        (EventType::ErrorProvider, "error.provider"),
        (EventType::SubagentSpawned, "subagent.spawned"),
        (EventType::SubagentStatusUpdate, "subagent.status_update"),
        (EventType::SubagentCompleted, "subagent.completed"),
        (EventType::SubagentFailed, "subagent.failed"),
        (EventType::SubagentResultsConsumed, "subagent.results_consumed"),
        (EventType::TodoWrite, "todo.write"),
        (EventType::TaskCreated, "task.created"),
        (EventType::TaskUpdated, "task.updated"),
        (EventType::TaskDeleted, "task.deleted"),
        (EventType::ProjectCreated, "project.created"),
        (EventType::ProjectUpdated, "project.updated"),
        (EventType::ProjectDeleted, "project.deleted"),
        (EventType::AreaCreated, "area.created"),
        (EventType::AreaUpdated, "area.updated"),
        (EventType::AreaDeleted, "area.deleted"),
        (EventType::TurnFailed, "turn.failed"),
        (EventType::HookTriggered, "hook.triggered"),
        (EventType::HookCompleted, "hook.completed"),
        (EventType::HookBackgroundStarted, "hook.background_started"),
        (EventType::HookBackgroundCompleted, "hook.background_completed"),
        (EventType::MemoryLedger, "memory.ledger"),
        (EventType::MemoryLoaded, "memory.loaded"),
    ];

    #[test]
    fn all_event_types_constant_has_59_variants() {
        assert_eq!(ALL_EVENT_TYPES.len(), 59);
    }

    #[test]
    fn all_event_types_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for et in &ALL_EVENT_TYPES {
            assert!(seen.insert(et), "duplicate event type: {et}");
        }
    }

    #[test]
    fn as_str_matches_expected() {
        for (variant, expected) in &EXPECTED {
            assert_eq!(variant.as_str(), *expected, "as_str mismatch for {variant:?}");
        }
    }

    #[test]
    fn display_matches_as_str() {
        for et in &ALL_EVENT_TYPES {
            assert_eq!(format!("{et}"), et.as_str());
        }
    }

    #[test]
    fn serde_roundtrip_all_variants() {
        for (variant, expected_str) in &EXPECTED {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, serde_json::Value::String(expected_str.to_string()),
                "serialize mismatch for {variant:?}");

            let back: EventType = serde_json::from_value(json).unwrap();
            assert_eq!(*variant, back, "roundtrip mismatch for {variant:?}");
        }
    }

    #[test]
    fn from_str_all_variants() {
        for (variant, expected_str) in &EXPECTED {
            let parsed: EventType = expected_str.parse().unwrap();
            assert_eq!(*variant, parsed);
        }
    }

    #[test]
    fn from_str_rejects_invalid() {
        let err = "not.a.type".parse::<EventType>();
        assert!(err.is_err());
        assert!(err.unwrap_err().contains("unknown event type"));
    }

    #[test]
    fn from_str_rejects_empty() {
        assert!("".parse::<EventType>().is_err());
    }

    // -- Domain helpers --

    #[test]
    fn is_message_type() {
        assert!(EventType::MessageUser.is_message_type());
        assert!(EventType::MessageAssistant.is_message_type());
        assert!(EventType::MessageSystem.is_message_type());
        assert!(!EventType::MessageDeleted.is_message_type());
        assert!(!EventType::ToolCall.is_message_type());
    }

    #[test]
    fn is_streaming_type() {
        assert!(EventType::StreamTextDelta.is_streaming_type());
        assert!(EventType::StreamThinkingDelta.is_streaming_type());
        assert!(EventType::StreamTurnStart.is_streaming_type());
        assert!(EventType::StreamTurnEnd.is_streaming_type());
        assert!(!EventType::MessageUser.is_streaming_type());
    }

    #[test]
    fn is_error_type() {
        assert!(EventType::ErrorAgent.is_error_type());
        assert!(EventType::ErrorTool.is_error_type());
        assert!(EventType::ErrorProvider.is_error_type());
        assert!(!EventType::ToolResult.is_error_type());
    }

    #[test]
    fn is_config_type() {
        assert!(EventType::ConfigModelSwitch.is_config_type());
        assert!(EventType::ConfigPromptUpdate.is_config_type());
        assert!(EventType::ConfigReasoningLevel.is_config_type());
        assert!(!EventType::SessionStart.is_config_type());
    }

    #[test]
    fn is_worktree_type() {
        assert!(EventType::WorktreeAcquired.is_worktree_type());
        assert!(EventType::WorktreeCommit.is_worktree_type());
        assert!(EventType::WorktreeReleased.is_worktree_type());
        assert!(EventType::WorktreeMerged.is_worktree_type());
        assert!(!EventType::FileRead.is_worktree_type());
    }

    #[test]
    fn is_subagent_type() {
        assert!(EventType::SubagentSpawned.is_subagent_type());
        assert!(EventType::SubagentStatusUpdate.is_subagent_type());
        assert!(EventType::SubagentCompleted.is_subagent_type());
        assert!(EventType::SubagentFailed.is_subagent_type());
        assert!(EventType::SubagentResultsConsumed.is_subagent_type());
        assert!(!EventType::SessionStart.is_subagent_type());
    }

    #[test]
    fn is_hook_type() {
        assert!(EventType::HookTriggered.is_hook_type());
        assert!(EventType::HookCompleted.is_hook_type());
        assert!(EventType::HookBackgroundStarted.is_hook_type());
        assert!(EventType::HookBackgroundCompleted.is_hook_type());
        assert!(!EventType::ToolCall.is_hook_type());
    }

    #[test]
    fn is_skill_type() {
        assert!(EventType::SkillAdded.is_skill_type());
        assert!(EventType::SkillRemoved.is_skill_type());
        assert!(!EventType::RulesLoaded.is_skill_type());
    }

    #[test]
    fn is_rules_type() {
        assert!(EventType::RulesLoaded.is_rules_type());
        assert!(EventType::RulesIndexed.is_rules_type());
        assert!(!EventType::SkillAdded.is_rules_type());
    }

    #[test]
    fn is_memory_type() {
        assert!(EventType::MemoryLedger.is_memory_type());
        assert!(EventType::MemoryLoaded.is_memory_type());
        assert!(!EventType::SessionStart.is_memory_type());
    }

    #[test]
    fn is_task_crud_type() {
        assert!(EventType::TaskCreated.is_task_crud_type());
        assert!(EventType::ProjectUpdated.is_task_crud_type());
        assert!(EventType::AreaDeleted.is_task_crud_type());
        assert!(!EventType::TodoWrite.is_task_crud_type());
    }

    #[test]
    fn is_session_type() {
        assert!(EventType::SessionStart.is_session_type());
        assert!(EventType::SessionEnd.is_session_type());
        assert!(EventType::SessionFork.is_session_type());
        assert!(!EventType::MessageUser.is_session_type());
    }

    #[test]
    fn is_file_type() {
        assert!(EventType::FileRead.is_file_type());
        assert!(EventType::FileWrite.is_file_type());
        assert!(EventType::FileEdit.is_file_type());
        assert!(!EventType::WorktreeCommit.is_file_type());
    }

    #[test]
    fn domain_extraction() {
        assert_eq!(EventType::SessionStart.domain(), "session");
        assert_eq!(EventType::MessageUser.domain(), "message");
        assert_eq!(EventType::ToolCall.domain(), "tool");
        assert_eq!(EventType::StreamTextDelta.domain(), "stream");
        assert_eq!(EventType::ConfigModelSwitch.domain(), "config");
        assert_eq!(EventType::CompactBoundary.domain(), "compact");
        assert_eq!(EventType::WorktreeAcquired.domain(), "worktree");
        assert_eq!(EventType::ErrorAgent.domain(), "error");
        assert_eq!(EventType::SubagentSpawned.domain(), "subagent");
        assert_eq!(EventType::HookTriggered.domain(), "hook");
        assert_eq!(EventType::MemoryLedger.domain(), "memory");
    }

    #[test]
    fn copy_semantics() {
        let a = EventType::SessionStart;
        let b = a;
        assert_eq!(a, b);
    }

    #[test]
    fn hash_and_eq() {
        use std::collections::HashSet;
        let mut set = HashSet::new();
        let _ = set.insert(EventType::SessionStart);
        let _ = set.insert(EventType::SessionStart);
        assert_eq!(set.len(), 1);
    }

    // -- proptest: roundtrip through serde --

    #[test]
    fn serde_roundtrip_from_string() {
        for et in &ALL_EVENT_TYPES {
            let s = et.as_str();
            let json_str = format!("\"{s}\"");
            let parsed: EventType = serde_json::from_str(&json_str).unwrap();
            assert_eq!(*et, parsed);
        }
    }
}

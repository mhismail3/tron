//! Auto-generated event type definitions.
//!
//! All definitions are produced by [`define_events!`] from a single
//! source-of-truth table. **Do not hand-edit the generated code** —
//! add or remove events by modifying the macro invocation below.

use serde::{Deserialize, Serialize};

use super::base::SessionEvent;
use super::payloads;

define_events! {
    events {
        /// New session started.
        SessionStart => "session.start" => payloads::session::SessionStartPayload,
        /// Session ended.
        SessionEnd => "session.end" => payloads::session::SessionEndPayload,
        /// Session forked from another.
        SessionFork => "session.fork" => payloads::session::SessionForkPayload,
        /// User message.
        MessageUser => "message.user" => payloads::message::UserMessagePayload,
        /// Assistant (model) message.
        MessageAssistant => "message.assistant" => payloads::message::AssistantMessagePayload,
        /// System-injected message.
        MessageSystem => "message.system" => payloads::message::SystemMessagePayload,
        /// Message deleted (soft delete).
        MessageDeleted => "message.deleted" => payloads::message_ops::MessageDeletedPayload,
        /// Tool call from the model.
        ToolCall => "tool.call" => payloads::tool::ToolCallPayload,
        /// Tool execution result.
        ToolResult => "tool.result" => payloads::tool::ToolResultPayload,
        /// Text delta during streaming.
        StreamTextDelta => "stream.text_delta" => payloads::streaming::StreamTextDeltaPayload,
        /// Thinking delta during streaming.
        StreamThinkingDelta => "stream.thinking_delta" => payloads::streaming::StreamThinkingDeltaPayload,
        /// Turn started streaming.
        StreamTurnStart => "stream.turn_start" => payloads::streaming::StreamTurnStartPayload,
        /// Turn finished streaming.
        StreamTurnEnd => "stream.turn_end" => payloads::streaming::StreamTurnEndPayload,
        /// Model switched.
        ConfigModelSwitch => "config.model_switch" => payloads::config::ConfigModelSwitchPayload,
        /// System prompt updated.
        ConfigPromptUpdate => "config.prompt_update" => payloads::config::ConfigPromptUpdatePayload,
        /// Reasoning level changed.
        ConfigReasoningLevel => "config.reasoning_level" => payloads::config::ConfigReasoningLevelPayload,
        /// Agent interrupted by user.
        NotificationInterrupted => "notification.interrupted" => payloads::notification::NotificationInterruptedPayload,
        /// Subagent result notification.
        NotificationSubagentResult => "notification.subagent_result" => payloads::notification::NotificationSubagentResultPayload,
        /// Compaction boundary marker.
        CompactBoundary => "compact.boundary" => payloads::compact::CompactBoundaryPayload,
        /// Compaction summary.
        CompactSummary => "compact.summary" => payloads::compact::CompactSummaryPayload,
        /// Context cleared.
        ContextCleared => "context.cleared" => payloads::context::ContextClearedPayload,
        /// Skill added to session.
        SkillAdded => "skill.added" => payloads::skill::SkillAddedPayload,
        /// Skill removed from session.
        SkillRemoved => "skill.removed" => payloads::skill::SkillRemovedPayload,
        /// Rules files loaded.
        RulesLoaded => "rules.loaded" => payloads::rules::RulesLoadedPayload,
        /// Rules indexed.
        RulesIndexed => "rules.indexed" => payloads::rules::RulesIndexedPayload,
        /// Scoped rules activated by file path touches.
        RulesActivated => "rules.activated" => payloads::rules::RulesActivatedPayload,
        /// Session metadata updated.
        MetadataUpdate => "metadata.update" => payloads::metadata::MetadataUpdatePayload,
        /// Session tag added/removed.
        MetadataTag => "metadata.tag" => payloads::metadata::MetadataTagPayload,
        /// File read by agent.
        FileRead => "file.read" => payloads::file::FileReadPayload,
        /// File written by agent.
        FileWrite => "file.write" => payloads::file::FileWritePayload,
        /// File edited by agent.
        FileEdit => "file.edit" => payloads::file::FileEditPayload,
        /// Git worktree acquired.
        WorktreeAcquired => "worktree.acquired" => payloads::worktree::WorktreeAcquiredPayload,
        /// Commit in worktree.
        WorktreeCommit => "worktree.commit" => payloads::worktree::WorktreeCommitPayload,
        /// Worktree released.
        WorktreeReleased => "worktree.released" => payloads::worktree::WorktreeReleasedPayload,
        /// Worktree merged back.
        WorktreeMerged => "worktree.merged" => payloads::worktree::WorktreeMergedPayload,
        /// Agent-level error.
        ErrorAgent => "error.agent" => payloads::error::ErrorAgentPayload,
        /// Tool execution error.
        ErrorTool => "error.tool" => payloads::error::ErrorToolPayload,
        /// Provider (LLM) error.
        ErrorProvider => "error.provider" => payloads::error::ErrorProviderPayload,
        /// Subagent spawned.
        SubagentSpawned => "subagent.spawned" => payloads::subagent::SubagentSpawnedPayload,
        /// Subagent status update.
        SubagentStatusUpdate => "subagent.status_update" => payloads::subagent::SubagentStatusUpdatePayload,
        /// Subagent completed.
        SubagentCompleted => "subagent.completed" => payloads::subagent::SubagentCompletedPayload,
        /// Subagent failed.
        SubagentFailed => "subagent.failed" => payloads::subagent::SubagentFailedPayload,
        /// Subagent results consumed by parent agent.
        SubagentResultsConsumed => "subagent.results_consumed" => payloads::notification::SubagentResultsConsumedPayload,
        /// Todo list written.
        TodoWrite => "todo.write" => payloads::todo::TodoWritePayload,
        /// Task created.
        TaskCreated => "task.created" => payloads::task::TaskCreatedPayload,
        /// Task updated.
        TaskUpdated => "task.updated" => payloads::task::TaskUpdatedPayload,
        /// Task deleted.
        TaskDeleted => "task.deleted" => payloads::task::TaskDeletedPayload,
        /// Project created.
        ProjectCreated => "project.created" => payloads::task::ProjectCreatedPayload,
        /// Project updated.
        ProjectUpdated => "project.updated" => payloads::task::ProjectUpdatedPayload,
        /// Project deleted.
        ProjectDeleted => "project.deleted" => payloads::task::ProjectDeletedPayload,
        /// Area created.
        AreaCreated => "area.created" => payloads::task::AreaCreatedPayload,
        /// Area updated.
        AreaUpdated => "area.updated" => payloads::task::AreaUpdatedPayload,
        /// Area deleted.
        AreaDeleted => "area.deleted" => payloads::task::AreaDeletedPayload,
        /// Turn failed.
        TurnFailed => "turn.failed" => payloads::turn::TurnFailedPayload,
        /// Hook triggered.
        HookTriggered => "hook.triggered" => payloads::hook::HookTriggeredPayload,
        /// Hook completed.
        HookCompleted => "hook.completed" => payloads::hook::HookCompletedPayload,
        /// Background hook started.
        HookBackgroundStarted => "hook.background_started" => payloads::hook::HookBackgroundStartedPayload,
        /// Background hook completed.
        HookBackgroundCompleted => "hook.background_completed" => payloads::hook::HookBackgroundCompletedPayload,
        /// Memory ledger entry.
        MemoryLedger => "memory.ledger" => payloads::memory::MemoryLedgerPayload,
    }
    raw_events {
        /// Memory loaded into context (raw payload).
        MemoryLoaded => "memory.loaded" => serde_json::Value,
    }
    domain_groups {
        /// Whether this is a session lifecycle event (`session.*`).
        is_session_type => [SessionStart, SessionEnd, SessionFork],
        /// Whether this is a message event (`message.user|assistant|system`).
        is_message_type => [MessageUser, MessageAssistant, MessageSystem],
        /// Whether this is a streaming event (`stream.*`).
        is_streaming_type => [StreamTextDelta, StreamThinkingDelta, StreamTurnStart, StreamTurnEnd],
        /// Whether this is an error event (`error.*`).
        is_error_type => [ErrorAgent, ErrorTool, ErrorProvider],
        /// Whether this is a config event (`config.*`).
        is_config_type => [ConfigModelSwitch, ConfigPromptUpdate, ConfigReasoningLevel],
        /// Whether this is a worktree event (`worktree.*`).
        is_worktree_type => [WorktreeAcquired, WorktreeCommit, WorktreeReleased, WorktreeMerged],
        /// Whether this is a subagent event (`subagent.*`).
        is_subagent_type => [SubagentSpawned, SubagentStatusUpdate, SubagentCompleted, SubagentFailed, SubagentResultsConsumed],
        /// Whether this is a hook event (`hook.*`).
        is_hook_type => [HookTriggered, HookCompleted, HookBackgroundStarted, HookBackgroundCompleted],
        /// Whether this is a skill event (`skill.*`).
        is_skill_type => [SkillAdded, SkillRemoved],
        /// Whether this is a rules event (`rules.*`).
        is_rules_type => [RulesLoaded, RulesIndexed, RulesActivated],
        /// Whether this is a memory event (`memory.*`).
        is_memory_type => [MemoryLedger, MemoryLoaded],
        /// Whether this is a task/project/area CRUD event.
        is_task_crud_type => [TaskCreated, TaskUpdated, TaskDeleted, ProjectCreated, ProjectUpdated, ProjectDeleted, AreaCreated, AreaUpdated, AreaDeleted],
        /// Whether this is a file event (`file.*`).
        is_file_type => [FileRead, FileWrite, FileEdit],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXPECTED: [(EventType, &str); 60] = [
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
        (EventType::RulesActivated, "rules.activated"),
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
    fn all_event_types_constant_has_60_variants() {
        assert_eq!(ALL_EVENT_TYPES.len(), 60);
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
    fn as_str_matches_serde() {
        for et in &ALL_EVENT_TYPES {
            let json = serde_json::to_value(et).unwrap();
            assert_eq!(json.as_str().unwrap(), et.as_str(), "serde mismatch for {et:?}");
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
            assert_eq!(
                json, serde_json::Value::String(expected_str.to_string()),
                "serialize mismatch for {variant:?}"
            );
            let back: EventType = serde_json::from_value(json).unwrap();
            assert_eq!(*variant, back, "roundtrip mismatch for {variant:?}");
        }
    }

    #[test]
    fn from_str_roundtrip() {
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

    #[test]
    fn serde_roundtrip_from_string() {
        for et in &ALL_EVENT_TYPES {
            let s = et.as_str();
            let json_str = format!("\"{s}\"");
            let parsed: EventType = serde_json::from_str(&json_str).unwrap();
            assert_eq!(*et, parsed);
        }
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

    #[test]
    fn into_typed_payload_matches_typed_payload() {
        let event = SessionEvent {
            id: "evt-1".into(),
            parent_id: None,
            session_id: "s".into(),
            workspace_id: "w".into(),
            timestamp: "t".into(),
            event_type: EventType::SessionStart,
            sequence: 1,
            checksum: None,
            payload: serde_json::json!({
                "workingDirectory": "/test",
                "model": "claude-opus-4-6",
                "provider": "anthropic"
            }),
        };
        let cloned = event.typed_payload().unwrap();
        let owned = event.into_typed_payload().unwrap();
        assert_eq!(cloned, owned);
    }
}

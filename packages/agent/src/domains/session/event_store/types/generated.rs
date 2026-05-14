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
        /// Message queued for later delivery (user sent while agent busy).
        MessageQueued => "message.queued" => payloads::message_ops::MessageQueuedPayload,
        /// Queued message consumed or cancelled.
        MessageDequeued => "message.dequeued" => payloads::message_ops::MessageDequeuedPayload,
        /// Capability invocation started.
        CapabilityInvocationStarted => "capability.invocation.started" => payloads::capability_invocation::CapabilityInvocationStartedPayload,
        /// Capability invocation completed.
        CapabilityInvocationCompleted => "capability.invocation.completed" => payloads::capability_invocation::CapabilityInvocationCompletedPayload,
        /// Capability invocation progress update.
        CapabilityInvocationProgress => "capability.invocation.progress" => payloads::capability_invocation::CapabilityInvocationProgressPayload,
        /// Capability pause requested.
        CapabilityPauseRequested => "capability.pause.requested" => payloads::capability_invocation::CapabilityPauseRequestedPayload,
        /// Capability pause resolved.
        CapabilityPauseResolved => "capability.pause.resolved" => payloads::capability_invocation::CapabilityPauseResolvedPayload,
        /// Capability async run status update.
        CapabilityRunStatus => "capability.run.status" => payloads::capability_invocation::CapabilityRunStatusPayload,
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
        /// Phase 1 of the H13 compaction two-phase commit: summary produced,
        /// boundary not yet committed. Durably preserves the summarizer's
        /// output before the context is mutated and the boundary persist is
        /// attempted. Reconstruction ignores a staging event without a
        /// matching successor `CompactBoundary`.
        CompactSummaryStaging => "compact.summary_staging" => payloads::compact::CompactSummaryStagingPayload,
        /// Compaction summary.
        CompactSummary => "compact.summary" => payloads::compact::CompactSummaryPayload,
        /// Context cleared.
        ContextCleared => "context.cleared" => payloads::context::ContextClearedPayload,
        /// Skill activated in session (server-owned state).
        SkillActivated => "skill.activated" => payloads::skill::SkillActivatedPayload,
        /// Skill deactivated from session.
        SkillDeactivated => "skill.deactivated" => payloads::skill::SkillDeactivatedPayload,
        /// Skills cleared (emitted on compaction with `askUser` policy).
        SkillsCleared => "skills.cleared" => payloads::skill::SkillsClearedPayload,
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
        /// Worktree branch renamed.
        WorktreeRenamed => "worktree.renamed" => payloads::worktree::WorktreeRenamedPayload,
        /// Agent-level error.
        ErrorAgent => "error.agent" => payloads::error::ErrorAgentPayload,
        /// Capability invocation error.
        ErrorCapability => "error.capability" => payloads::error::ErrorCapabilityPayload,
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
        /// Background process result notification.
        NotificationProcessResult => "notification.process_result" => payloads::notification::NotificationProcessResultPayload,
        /// Process results consumed by agent.
        ProcessResultsConsumed => "process.results_consumed" => payloads::notification::ProcessResultsConsumedPayload,
        /// User backgrounded or cancelled a job from iOS.
        NotificationUserJobAction => "notification.user_job_action" => payloads::notification::UserJobActionPayload,
        /// User job actions consumed by agent (marks them as processed).
        UserJobActionsConsumed => "user_job_actions.consumed" => payloads::notification::UserJobActionsConsumedPayload,
        /// Todo list written.
        TodoWrite => "todo.write" => payloads::todo::TodoWritePayload,
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
        /// LLM hook result (prompt-based hook completed).
        LlmHookResult => "hook.llm_result" => payloads::hook::LlmHookResultPayload,
        /// Memory retained (marks boundary for next Retain operation).
        MemoryRetained => "memory.retained" => payloads::memory::MemoryRetainedPayload,
        /// Auto-retain threshold crossed; retain pipeline starting.
        MemoryAutoRetainTriggered => "memory.auto_retain_triggered" => payloads::memory::MemoryAutoRetainTriggeredPayload,
        /// Auto-retain pipeline failed (or was orphaned by a server restart).
        MemoryAutoRetainFailed => "memory.auto_retain_failed" => payloads::memory::MemoryAutoRetainFailedPayload,
        /// Local main fast-forwarded from remote.
        WorktreeMainSynced => "worktree.main_synced" => payloads::worktree::WorktreeMainSyncedPayload,
        /// Session finalized (merge + rebranch).
        WorktreeSessionFinalized => "worktree.session_finalized" => payloads::worktree::WorktreeSessionFinalizedPayload,
        /// Merge started with conflicts kept on disk.
        WorktreeMergeStarted => "worktree.merge_started" => payloads::worktree::WorktreeMergeStartedPayload,
        /// Conflict(s) detected in an in-flight merge.
        WorktreeConflictDetected => "worktree.conflict_detected" => payloads::worktree::WorktreeConflictDetectedPayload,
        /// Single conflict resolved.
        WorktreeConflictResolved => "worktree.conflict_resolved" => payloads::worktree::WorktreeConflictResolvedPayload,
        /// In-flight merge continued after conflicts cleared.
        WorktreeMergeContinued => "worktree.merge_continued" => payloads::worktree::WorktreeMergeContinuedPayload,
        /// In-flight merge aborted.
        WorktreeMergeAborted => "worktree.merge_aborted" => payloads::worktree::WorktreeMergeAbortedPayload,
        /// Branch pushed to remote.
        WorktreePushed => "worktree.pushed" => payloads::worktree::WorktreePushedPayload,
        /// Pending merge detected during crash recovery.
        WorktreePendingMergeDetected => "worktree.pending_merge_detected" => payloads::worktree::WorktreePendingMergeDetectedPayload,
        /// Session branch rebased onto main (clean or post-conflict resolution).
        WorktreeRebasedOnMain => "worktree.rebased_on_main" => payloads::worktree::WorktreeRebasedOnMainPayload,
        /// `git stash pop` after a successful rebase produced unmerged paths.
        WorktreePostRebaseStashConflict => "worktree.post_rebase_stash_conflict" => payloads::worktree::WorktreePostRebaseStashConflictPayload,
        /// Auto-committed orphan changes during worktree recovery/deletion.
        WorktreeAutoRecoveredCommits => "worktree.auto_recovered_commits" => payloads::worktree::WorktreeAutoRecoveredCommitsPayload,
        /// Per-repo lock acquired by a session.
        RepoLockAcquired => "repo.lock_acquired" => payloads::repo::RepoLockAcquiredPayload,
        /// Per-repo lock released.
        RepoLockReleased => "repo.lock_released" => payloads::repo::RepoLockReleasedPayload,
        /// Main branch advanced in a repo (cross-session broadcast).
        RepoMainAdvanced => "repo.main_advanced" => payloads::repo::RepoMainAdvancedPayload,
        /// APNS device token invalidated by Apple (410 / BadDeviceToken /
        /// DeviceTokenNotForTopic). Row already deactivated in the DB;
        /// this event is the audit trail + broadcast signal for iOS.
        DeviceTokenInvalidated => "device.token_invalidated" => payloads::device::DeviceTokenInvalidatedPayload,
        /// User-mode update checker observed a newer release on the
        /// configured channel.
        ServerUpdateAvailable => "server.update_available" => payloads::server::ServerUpdateAvailablePayload,
    }
    raw_events {
    }
    domain_groups {
        /// Whether this is a session lifecycle event (`session.*`).
        is_session_type => [SessionStart, SessionEnd, SessionFork],
        /// Whether this is a message event (`message.user|assistant|system`).
        is_message_type => [MessageUser, MessageAssistant, MessageSystem],
        /// Whether this is a streaming event (`stream.*`).
        is_streaming_type => [StreamTextDelta, StreamThinkingDelta, StreamTurnStart, StreamTurnEnd],
        /// Whether this is an error event (`error.*`).
        is_error_type => [ErrorAgent, ErrorCapability, ErrorProvider],
        /// Whether this is a config event (`config.*`).
        is_config_type => [ConfigModelSwitch, ConfigPromptUpdate, ConfigReasoningLevel],
        /// Whether this is a worktree event (`worktree.*`).
        is_worktree_type => [
            WorktreeAcquired, WorktreeCommit, WorktreeReleased, WorktreeMerged, WorktreeRenamed,
            WorktreeMainSynced, WorktreeSessionFinalized,
            WorktreeMergeStarted, WorktreeConflictDetected, WorktreeConflictResolved,
            WorktreeMergeContinued, WorktreeMergeAborted, WorktreePushed,
            WorktreePendingMergeDetected, WorktreeRebasedOnMain,
            WorktreePostRebaseStashConflict, WorktreeAutoRecoveredCommits
        ],
        /// Whether this is a repo-wide event (`repo.*`).
        is_repo_type => [RepoLockAcquired, RepoLockReleased, RepoMainAdvanced],
        /// Whether this is a subagent event (`subagent.*`).
        is_subagent_type => [SubagentSpawned, SubagentStatusUpdate, SubagentCompleted, SubagentFailed, SubagentResultsConsumed],
        /// Whether this is a hook event (`hook.*`).
        is_hook_type => [HookTriggered, HookCompleted, HookBackgroundStarted, HookBackgroundCompleted, LlmHookResult],
        /// Whether this is a skill event (`skill.*`).
        is_skill_type => [SkillActivated, SkillDeactivated, SkillsCleared],
        /// Whether this is a rules event (`rules.*`).
        is_rules_type => [RulesLoaded, RulesIndexed, RulesActivated],
        /// Whether this is a queue event (`message.queued|dequeued`).
        is_queue_type => [MessageQueued, MessageDequeued],
        /// Whether this is a file event (`file.*`).
        is_file_type => [FileRead, FileWrite, FileEdit],
        /// Whether this is a server lifecycle event (`server.*`).
        is_server_type => [
            ServerUpdateAvailable
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXPECTED: [(EventType, &str); 83] = [
        (EventType::SessionStart, "session.start"),
        (EventType::SessionEnd, "session.end"),
        (EventType::SessionFork, "session.fork"),
        (EventType::MessageUser, "message.user"),
        (EventType::MessageAssistant, "message.assistant"),
        (EventType::MessageSystem, "message.system"),
        (EventType::MessageDeleted, "message.deleted"),
        (EventType::MessageQueued, "message.queued"),
        (EventType::MessageDequeued, "message.dequeued"),
        (
            EventType::CapabilityInvocationStarted,
            "capability.invocation.started",
        ),
        (
            EventType::CapabilityInvocationCompleted,
            "capability.invocation.completed",
        ),
        (
            EventType::CapabilityInvocationProgress,
            "capability.invocation.progress",
        ),
        (
            EventType::CapabilityPauseRequested,
            "capability.pause.requested",
        ),
        (
            EventType::CapabilityPauseResolved,
            "capability.pause.resolved",
        ),
        (EventType::CapabilityRunStatus, "capability.run.status"),
        (EventType::StreamTextDelta, "stream.text_delta"),
        (EventType::StreamThinkingDelta, "stream.thinking_delta"),
        (EventType::StreamTurnStart, "stream.turn_start"),
        (EventType::StreamTurnEnd, "stream.turn_end"),
        (EventType::ConfigModelSwitch, "config.model_switch"),
        (EventType::ConfigPromptUpdate, "config.prompt_update"),
        (EventType::ConfigReasoningLevel, "config.reasoning_level"),
        (
            EventType::NotificationInterrupted,
            "notification.interrupted",
        ),
        (
            EventType::NotificationSubagentResult,
            "notification.subagent_result",
        ),
        (EventType::CompactBoundary, "compact.boundary"),
        (EventType::CompactSummary, "compact.summary"),
        (EventType::CompactSummaryStaging, "compact.summary_staging"),
        (EventType::ContextCleared, "context.cleared"),
        (EventType::SkillActivated, "skill.activated"),
        (EventType::SkillDeactivated, "skill.deactivated"),
        (EventType::SkillsCleared, "skills.cleared"),
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
        (EventType::WorktreeRenamed, "worktree.renamed"),
        (EventType::ErrorAgent, "error.agent"),
        (EventType::ErrorCapability, "error.capability"),
        (EventType::ErrorProvider, "error.provider"),
        (EventType::SubagentSpawned, "subagent.spawned"),
        (EventType::SubagentStatusUpdate, "subagent.status_update"),
        (EventType::SubagentCompleted, "subagent.completed"),
        (EventType::SubagentFailed, "subagent.failed"),
        (
            EventType::SubagentResultsConsumed,
            "subagent.results_consumed",
        ),
        (
            EventType::NotificationProcessResult,
            "notification.process_result",
        ),
        (
            EventType::ProcessResultsConsumed,
            "process.results_consumed",
        ),
        (
            EventType::NotificationUserJobAction,
            "notification.user_job_action",
        ),
        (
            EventType::UserJobActionsConsumed,
            "user_job_actions.consumed",
        ),
        (EventType::TodoWrite, "todo.write"),
        (EventType::TurnFailed, "turn.failed"),
        (EventType::HookTriggered, "hook.triggered"),
        (EventType::HookCompleted, "hook.completed"),
        (EventType::HookBackgroundStarted, "hook.background_started"),
        (
            EventType::HookBackgroundCompleted,
            "hook.background_completed",
        ),
        (EventType::LlmHookResult, "hook.llm_result"),
        (EventType::MemoryRetained, "memory.retained"),
        (
            EventType::MemoryAutoRetainTriggered,
            "memory.auto_retain_triggered",
        ),
        (
            EventType::MemoryAutoRetainFailed,
            "memory.auto_retain_failed",
        ),
        (EventType::WorktreeMainSynced, "worktree.main_synced"),
        (
            EventType::WorktreeSessionFinalized,
            "worktree.session_finalized",
        ),
        (EventType::WorktreeMergeStarted, "worktree.merge_started"),
        (
            EventType::WorktreeConflictDetected,
            "worktree.conflict_detected",
        ),
        (
            EventType::WorktreeConflictResolved,
            "worktree.conflict_resolved",
        ),
        (
            EventType::WorktreeMergeContinued,
            "worktree.merge_continued",
        ),
        (EventType::WorktreeMergeAborted, "worktree.merge_aborted"),
        (EventType::WorktreePushed, "worktree.pushed"),
        (
            EventType::WorktreePendingMergeDetected,
            "worktree.pending_merge_detected",
        ),
        (EventType::WorktreeRebasedOnMain, "worktree.rebased_on_main"),
        (
            EventType::WorktreePostRebaseStashConflict,
            "worktree.post_rebase_stash_conflict",
        ),
        (
            EventType::WorktreeAutoRecoveredCommits,
            "worktree.auto_recovered_commits",
        ),
        (EventType::RepoLockAcquired, "repo.lock_acquired"),
        (EventType::RepoLockReleased, "repo.lock_released"),
        (EventType::RepoMainAdvanced, "repo.main_advanced"),
        (
            EventType::DeviceTokenInvalidated,
            "device.token_invalidated",
        ),
        (EventType::ServerUpdateAvailable, "server.update_available"),
    ];

    #[test]
    fn all_event_types_constant_has_correct_count() {
        assert_eq!(ALL_EVENT_TYPES.len(), 83);
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
            assert_eq!(
                variant.as_str(),
                *expected,
                "as_str mismatch for {variant:?}"
            );
        }
    }

    #[test]
    fn as_str_matches_serde() {
        for et in &ALL_EVENT_TYPES {
            let json = serde_json::to_value(et).unwrap();
            assert_eq!(
                json.as_str().unwrap(),
                et.as_str(),
                "serde mismatch for {et:?}"
            );
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
                json,
                serde_json::Value::String(expected_str.to_string()),
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
    fn from_str_rejects_retired_spell_types() {
        // Post-removal invariant: the removed spell event-type strings must
        // fail to parse. Retired rows in existing DBs are filtered out by the
        // v003 migration, so this guards against regressions that reintroduce
        // the variants.
        assert!("spell.cast".parse::<EventType>().is_err());
        assert!("spell.consumed".parse::<EventType>().is_err());
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
        assert!(!EventType::CapabilityInvocationStarted.is_message_type());
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
        assert!(EventType::ErrorCapability.is_error_type());
        assert!(EventType::ErrorProvider.is_error_type());
        assert!(!EventType::CapabilityInvocationCompleted.is_error_type());
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
    fn is_queue_type() {
        assert!(EventType::MessageQueued.is_queue_type());
        assert!(EventType::MessageDequeued.is_queue_type());
        assert!(!EventType::MessageUser.is_queue_type());
        assert!(!EventType::MessageDeleted.is_queue_type());
    }

    #[test]
    fn domain_extraction() {
        assert_eq!(EventType::SessionStart.domain(), "session");
        assert_eq!(EventType::MessageUser.domain(), "message");
        assert_eq!(
            EventType::CapabilityInvocationStarted.domain(),
            "capability"
        );
        assert_eq!(EventType::StreamTextDelta.domain(), "stream");
        assert_eq!(EventType::ConfigModelSwitch.domain(), "config");
        assert_eq!(EventType::CompactBoundary.domain(), "compact");
        assert_eq!(EventType::WorktreeAcquired.domain(), "worktree");
        assert_eq!(EventType::ErrorAgent.domain(), "error");
        assert_eq!(EventType::SubagentSpawned.domain(), "subagent");
        assert_eq!(EventType::HookTriggered.domain(), "hook");
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

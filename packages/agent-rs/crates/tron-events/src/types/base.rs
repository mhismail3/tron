//! The [`SessionEvent`] struct — the core persisted event type.
//!
//! Events are stored as a flat struct with base fields at the top level
//! and a `payload` stored as opaque [`serde_json::Value`]. This matches
//! the TypeScript storage format exactly for wire compatibility.
//!
//! Typed access to the payload is opt-in via [`SessionEvent::typed_payload()`],
//! which dispatches on [`EventType`] and deserializes into the appropriate
//! payload struct.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::event_type::EventType;
use super::payloads;

/// A persisted session event.
///
/// The canonical wire format has base fields (`id`, `parentId`, `sessionId`,
/// etc.) at the top level and a `payload` JSON object. The payload is stored
/// as opaque `serde_json::Value` for exact wire compatibility.
///
/// Use [`typed_payload()`](Self::typed_payload) for compile-time-safe payload access.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEvent {
    /// Unique event ID (UUID v7).
    pub id: String,
    /// Parent event ID (`null` for root events).
    pub parent_id: Option<String>,
    /// Session this event belongs to.
    pub session_id: String,
    /// Workspace this event belongs to.
    pub workspace_id: String,
    /// ISO 8601 timestamp.
    pub timestamp: String,
    /// Event type discriminator.
    #[serde(rename = "type")]
    pub event_type: EventType,
    /// Monotonic sequence number within the session.
    pub sequence: i64,
    /// Integrity checksum.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checksum: Option<String>,
    /// Event-specific data (opaque JSON).
    pub payload: Value,
}

/// Typed payload enum for compile-time-safe access.
///
/// Obtained via [`SessionEvent::typed_payload()`]. Each variant wraps
/// the strongly-typed payload struct for its event type.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionEventPayload {
    /// `session.start`
    SessionStart(payloads::session::SessionStartPayload),
    /// `session.end`
    SessionEnd(payloads::session::SessionEndPayload),
    /// `session.fork`
    SessionFork(payloads::session::SessionForkPayload),
    /// `message.user`
    MessageUser(payloads::message::UserMessagePayload),
    /// `message.assistant`
    MessageAssistant(payloads::message::AssistantMessagePayload),
    /// `message.system`
    MessageSystem(payloads::message::SystemMessagePayload),
    /// `message.deleted`
    MessageDeleted(payloads::message_ops::MessageDeletedPayload),
    /// `tool.call`
    ToolCall(payloads::tool::ToolCallPayload),
    /// `tool.result`
    ToolResult(payloads::tool::ToolResultPayload),
    /// `stream.turn_start`
    StreamTurnStart(payloads::streaming::StreamTurnStartPayload),
    /// `stream.turn_end`
    StreamTurnEnd(payloads::streaming::StreamTurnEndPayload),
    /// `stream.text_delta`
    StreamTextDelta(payloads::streaming::StreamTextDeltaPayload),
    /// `stream.thinking_delta`
    StreamThinkingDelta(payloads::streaming::StreamThinkingDeltaPayload),
    /// `config.model_switch`
    ConfigModelSwitch(payloads::config::ConfigModelSwitchPayload),
    /// `config.prompt_update`
    ConfigPromptUpdate(payloads::config::ConfigPromptUpdatePayload),
    /// `config.reasoning_level`
    ConfigReasoningLevel(payloads::config::ConfigReasoningLevelPayload),
    /// `notification.interrupted`
    NotificationInterrupted(payloads::notification::NotificationInterruptedPayload),
    /// `notification.subagent_result`
    NotificationSubagentResult(payloads::notification::NotificationSubagentResultPayload),
    /// `compact.boundary`
    CompactBoundary(payloads::compact::CompactBoundaryPayload),
    /// `compact.summary`
    CompactSummary(payloads::compact::CompactSummaryPayload),
    /// `context.cleared`
    ContextCleared(payloads::context::ContextClearedPayload),
    /// `skill.added`
    SkillAdded(payloads::skill::SkillAddedPayload),
    /// `skill.removed`
    SkillRemoved(payloads::skill::SkillRemovedPayload),
    /// `rules.loaded`
    RulesLoaded(payloads::rules::RulesLoadedPayload),
    /// `rules.indexed`
    RulesIndexed(payloads::rules::RulesIndexedPayload),
    /// `rules.activated`
    RulesActivated(payloads::rules::RulesActivatedPayload),
    /// `metadata.update`
    MetadataUpdate(payloads::metadata::MetadataUpdatePayload),
    /// `metadata.tag`
    MetadataTag(payloads::metadata::MetadataTagPayload),
    /// `file.read`
    FileRead(payloads::file::FileReadPayload),
    /// `file.write`
    FileWrite(payloads::file::FileWritePayload),
    /// `file.edit`
    FileEdit(payloads::file::FileEditPayload),
    /// `worktree.acquired`
    WorktreeAcquired(payloads::worktree::WorktreeAcquiredPayload),
    /// `worktree.commit`
    WorktreeCommit(payloads::worktree::WorktreeCommitPayload),
    /// `worktree.released`
    WorktreeReleased(payloads::worktree::WorktreeReleasedPayload),
    /// `worktree.merged`
    WorktreeMerged(payloads::worktree::WorktreeMergedPayload),
    /// `error.agent`
    ErrorAgent(payloads::error::ErrorAgentPayload),
    /// `error.tool`
    ErrorTool(payloads::error::ErrorToolPayload),
    /// `error.provider`
    ErrorProvider(payloads::error::ErrorProviderPayload),
    /// `subagent.spawned`
    SubagentSpawned(payloads::subagent::SubagentSpawnedPayload),
    /// `subagent.status_update`
    SubagentStatusUpdate(payloads::subagent::SubagentStatusUpdatePayload),
    /// `subagent.completed`
    SubagentCompleted(payloads::subagent::SubagentCompletedPayload),
    /// `subagent.failed`
    SubagentFailed(payloads::subagent::SubagentFailedPayload),
    /// `subagent.results_consumed`
    SubagentResultsConsumed(payloads::notification::SubagentResultsConsumedPayload),
    /// `todo.write`
    TodoWrite(payloads::todo::TodoWritePayload),
    /// `task.created`
    TaskCreated(payloads::task::TaskCreatedPayload),
    /// `task.updated`
    TaskUpdated(payloads::task::TaskUpdatedPayload),
    /// `task.deleted`
    TaskDeleted(payloads::task::TaskDeletedPayload),
    /// `project.created`
    ProjectCreated(payloads::task::ProjectCreatedPayload),
    /// `project.updated`
    ProjectUpdated(payloads::task::ProjectUpdatedPayload),
    /// `project.deleted`
    ProjectDeleted(payloads::task::ProjectDeletedPayload),
    /// `area.created`
    AreaCreated(payloads::task::AreaCreatedPayload),
    /// `area.updated`
    AreaUpdated(payloads::task::AreaUpdatedPayload),
    /// `area.deleted`
    AreaDeleted(payloads::task::AreaDeletedPayload),
    /// `turn.failed`
    TurnFailed(payloads::turn::TurnFailedPayload),
    /// `hook.triggered`
    HookTriggered(payloads::hook::HookTriggeredPayload),
    /// `hook.completed`
    HookCompleted(payloads::hook::HookCompletedPayload),
    /// `hook.background_started`
    HookBackgroundStarted(payloads::hook::HookBackgroundStartedPayload),
    /// `hook.background_completed`
    HookBackgroundCompleted(payloads::hook::HookBackgroundCompletedPayload),
    /// `memory.ledger`
    MemoryLedger(payloads::memory::MemoryLedgerPayload),
    /// `memory.loaded`
    MemoryLoaded(payloads::memory::MemoryLoadedPayload),
}

impl SessionEvent {
    /// Deserialize the payload into the typed variant matching [`event_type`](Self::event_type).
    ///
    /// Returns `Err` if the payload JSON doesn't match the expected shape.
    #[allow(clippy::too_many_lines)]
    pub fn typed_payload(&self) -> std::result::Result<SessionEventPayload, serde_json::Error> {
        match self.event_type {
            EventType::SessionStart => Ok(SessionEventPayload::SessionStart(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::SessionEnd => Ok(SessionEventPayload::SessionEnd(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::SessionFork => Ok(SessionEventPayload::SessionFork(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::MessageUser => Ok(SessionEventPayload::MessageUser(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::MessageAssistant => Ok(SessionEventPayload::MessageAssistant(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::MessageSystem => Ok(SessionEventPayload::MessageSystem(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::MessageDeleted => Ok(SessionEventPayload::MessageDeleted(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::ToolCall => Ok(SessionEventPayload::ToolCall(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::ToolResult => Ok(SessionEventPayload::ToolResult(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::StreamTurnStart => Ok(SessionEventPayload::StreamTurnStart(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::StreamTurnEnd => Ok(SessionEventPayload::StreamTurnEnd(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::StreamTextDelta => Ok(SessionEventPayload::StreamTextDelta(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::StreamThinkingDelta => Ok(SessionEventPayload::StreamThinkingDelta(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::ConfigModelSwitch => Ok(SessionEventPayload::ConfigModelSwitch(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::ConfigPromptUpdate => Ok(SessionEventPayload::ConfigPromptUpdate(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::ConfigReasoningLevel => Ok(SessionEventPayload::ConfigReasoningLevel(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::NotificationInterrupted => Ok(SessionEventPayload::NotificationInterrupted(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::NotificationSubagentResult => {
                Ok(SessionEventPayload::NotificationSubagentResult(
                    serde_json::from_value(self.payload.clone())?,
                ))
            }
            EventType::CompactBoundary => Ok(SessionEventPayload::CompactBoundary(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::CompactSummary => Ok(SessionEventPayload::CompactSummary(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::ContextCleared => Ok(SessionEventPayload::ContextCleared(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::SkillAdded => Ok(SessionEventPayload::SkillAdded(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::SkillRemoved => Ok(SessionEventPayload::SkillRemoved(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::RulesLoaded => Ok(SessionEventPayload::RulesLoaded(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::RulesIndexed => Ok(SessionEventPayload::RulesIndexed(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::RulesActivated => Ok(SessionEventPayload::RulesActivated(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::MetadataUpdate => Ok(SessionEventPayload::MetadataUpdate(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::MetadataTag => Ok(SessionEventPayload::MetadataTag(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::FileRead => Ok(SessionEventPayload::FileRead(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::FileWrite => Ok(SessionEventPayload::FileWrite(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::FileEdit => Ok(SessionEventPayload::FileEdit(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::WorktreeAcquired => Ok(SessionEventPayload::WorktreeAcquired(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::WorktreeCommit => Ok(SessionEventPayload::WorktreeCommit(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::WorktreeReleased => Ok(SessionEventPayload::WorktreeReleased(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::WorktreeMerged => Ok(SessionEventPayload::WorktreeMerged(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::ErrorAgent => Ok(SessionEventPayload::ErrorAgent(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::ErrorTool => Ok(SessionEventPayload::ErrorTool(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::ErrorProvider => Ok(SessionEventPayload::ErrorProvider(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::SubagentSpawned => Ok(SessionEventPayload::SubagentSpawned(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::SubagentStatusUpdate => Ok(SessionEventPayload::SubagentStatusUpdate(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::SubagentCompleted => Ok(SessionEventPayload::SubagentCompleted(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::SubagentFailed => Ok(SessionEventPayload::SubagentFailed(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::SubagentResultsConsumed => Ok(SessionEventPayload::SubagentResultsConsumed(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::TodoWrite => Ok(SessionEventPayload::TodoWrite(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::TaskCreated => Ok(SessionEventPayload::TaskCreated(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::TaskUpdated => Ok(SessionEventPayload::TaskUpdated(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::TaskDeleted => Ok(SessionEventPayload::TaskDeleted(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::ProjectCreated => Ok(SessionEventPayload::ProjectCreated(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::ProjectUpdated => Ok(SessionEventPayload::ProjectUpdated(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::ProjectDeleted => Ok(SessionEventPayload::ProjectDeleted(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::AreaCreated => Ok(SessionEventPayload::AreaCreated(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::AreaUpdated => Ok(SessionEventPayload::AreaUpdated(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::AreaDeleted => Ok(SessionEventPayload::AreaDeleted(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::TurnFailed => Ok(SessionEventPayload::TurnFailed(serde_json::from_value(
                self.payload.clone(),
            )?)),
            EventType::HookTriggered => Ok(SessionEventPayload::HookTriggered(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::HookCompleted => Ok(SessionEventPayload::HookCompleted(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::HookBackgroundStarted => Ok(SessionEventPayload::HookBackgroundStarted(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::HookBackgroundCompleted => Ok(SessionEventPayload::HookBackgroundCompleted(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::MemoryLedger => Ok(SessionEventPayload::MemoryLedger(
                serde_json::from_value(self.payload.clone())?,
            )),
            EventType::MemoryLoaded => Ok(SessionEventPayload::MemoryLoaded(self.payload.clone())),
        }
    }
}

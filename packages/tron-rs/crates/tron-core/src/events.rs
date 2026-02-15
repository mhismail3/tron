use serde::{Deserialize, Serialize};

use crate::ids::{AgentId, SessionId, ToolCallId};
use crate::tokens::TokenUsage;

/// Agent lifecycle events emitted during execution.
/// These are the internal engine events, not to be confused with persistence events.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AgentEvent {
    #[serde(rename = "turn_start")]
    TurnStart {
        session_id: SessionId,
        agent_id: AgentId,
        turn: u32,
    },

    #[serde(rename = "text_delta")]
    TextDelta {
        session_id: SessionId,
        agent_id: AgentId,
        delta: String,
    },

    #[serde(rename = "thinking_delta")]
    ThinkingDelta {
        session_id: SessionId,
        agent_id: AgentId,
        delta: String,
    },

    #[serde(rename = "tool_start")]
    ToolStart {
        session_id: SessionId,
        agent_id: AgentId,
        tool_call_id: ToolCallId,
        tool_name: String,
    },

    #[serde(rename = "tool_end")]
    ToolEnd {
        session_id: SessionId,
        agent_id: AgentId,
        tool_call_id: ToolCallId,
        result_preview: String,
        duration_ms: u64,
    },

    #[serde(rename = "turn_complete")]
    TurnComplete {
        session_id: SessionId,
        agent_id: AgentId,
        turn: u32,
        usage: TokenUsage,
    },

    #[serde(rename = "agent_complete")]
    AgentComplete {
        session_id: SessionId,
        agent_id: AgentId,
    },

    /// MUST follow AgentComplete. iOS depends on this ordering.
    #[serde(rename = "agent_ready")]
    AgentReady {
        session_id: SessionId,
        agent_id: AgentId,
    },

    #[serde(rename = "subagent_spawned")]
    SubagentSpawned {
        parent_session_id: SessionId,
        parent_agent_id: AgentId,
        child_agent_id: AgentId,
    },

    #[serde(rename = "subagent_complete")]
    SubagentComplete {
        parent_session_id: SessionId,
        parent_agent_id: AgentId,
        child_agent_id: AgentId,
        result: String,
    },

    #[serde(rename = "compaction_started")]
    CompactionStarted {
        session_id: SessionId,
    },

    #[serde(rename = "compaction_complete")]
    CompactionComplete {
        session_id: SessionId,
        tokens_before: u32,
        tokens_after: u32,
    },
}

impl AgentEvent {
    pub fn session_id(&self) -> &SessionId {
        match self {
            Self::TurnStart { session_id, .. }
            | Self::TextDelta { session_id, .. }
            | Self::ThinkingDelta { session_id, .. }
            | Self::ToolStart { session_id, .. }
            | Self::ToolEnd { session_id, .. }
            | Self::TurnComplete { session_id, .. }
            | Self::AgentComplete { session_id, .. }
            | Self::AgentReady { session_id, .. }
            | Self::CompactionStarted { session_id, .. }
            | Self::CompactionComplete { session_id, .. } => session_id,
            Self::SubagentSpawned { parent_session_id, .. }
            | Self::SubagentComplete { parent_session_id, .. } => parent_session_id,
        }
    }

    pub fn event_type(&self) -> &'static str {
        match self {
            Self::TurnStart { .. } => "turn_start",
            Self::TextDelta { .. } => "text_delta",
            Self::ThinkingDelta { .. } => "thinking_delta",
            Self::ToolStart { .. } => "tool_start",
            Self::ToolEnd { .. } => "tool_end",
            Self::TurnComplete { .. } => "turn_complete",
            Self::AgentComplete { .. } => "agent_complete",
            Self::AgentReady { .. } => "agent_ready",
            Self::SubagentSpawned { .. } => "subagent_spawned",
            Self::SubagentComplete { .. } => "subagent_complete",
            Self::CompactionStarted { .. } => "compaction_started",
            Self::CompactionComplete { .. } => "compaction_complete",
        }
    }
}

/// Persistence event types (stored in SQLite).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PersistenceEventType {
    SessionStart,
    SessionFork,
    MessageUser,
    MessageAssistant,
    ToolCall,
    ToolResult,
    ContextCleared,
    CompactBoundary,
    CompactSummary,
    ConfigModelSwitched,
    StreamTurnStart,
    StreamTurnEnd,
    SkillAdded,
    SkillRemoved,
    MemoryLedger,
}

impl std::fmt::Display for PersistenceEventType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = serde_json::to_value(self)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| format!("{:?}", self));
        f.write_str(&s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_event_session_id() {
        let sid = SessionId::new();
        let aid = AgentId::new();
        let evt = AgentEvent::TurnStart {
            session_id: sid.clone(),
            agent_id: aid,
            turn: 1,
        };
        assert_eq!(evt.session_id(), &sid);
    }

    #[test]
    fn agent_event_type_str() {
        let evt = AgentEvent::AgentReady {
            session_id: SessionId::new(),
            agent_id: AgentId::new(),
        };
        assert_eq!(evt.event_type(), "agent_ready");
    }

    #[test]
    fn subagent_event_session_id() {
        let parent_sid = SessionId::new();
        let evt = AgentEvent::SubagentSpawned {
            parent_session_id: parent_sid.clone(),
            parent_agent_id: AgentId::new(),
            child_agent_id: AgentId::new(),
        };
        assert_eq!(evt.session_id(), &parent_sid);
    }

    #[test]
    fn persistence_event_type_display() {
        assert_eq!(PersistenceEventType::MessageUser.to_string(), "message_user");
        assert_eq!(PersistenceEventType::StreamTurnEnd.to_string(), "stream_turn_end");
        assert_eq!(PersistenceEventType::CompactBoundary.to_string(), "compact_boundary");
    }

    #[test]
    fn agent_event_serde_roundtrip() {
        let events = vec![
            AgentEvent::TurnStart {
                session_id: SessionId::new(),
                agent_id: AgentId::new(),
                turn: 1,
            },
            AgentEvent::TextDelta {
                session_id: SessionId::new(),
                agent_id: AgentId::new(),
                delta: "hello".into(),
            },
            AgentEvent::CompactionComplete {
                session_id: SessionId::new(),
                tokens_before: 50000,
                tokens_after: 10000,
            },
        ];

        for evt in &events {
            let json = serde_json::to_string(evt).unwrap();
            let parsed: AgentEvent = serde_json::from_str(&json).unwrap();
            let json2 = serde_json::to_string(&parsed).unwrap();
            assert_eq!(json, json2);
        }
    }
}

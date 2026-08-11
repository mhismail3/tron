//! Deterministic semantic-message repair for assignments and wake causes.

use serde_json::json;
use sha2::{Digest, Sha256};

use super::AgentExecutionService;
use crate::domains::agent::coordination::{AssignmentKind, AssignmentRecord, WakeIntentRecord};
use crate::domains::session::event_store::NewAgentMessageMetadata;
use crate::shared::protocol::messages::{
    AgentMessageAuthority, AgentMessageContent, AgentMessageKind,
};

impl AgentExecutionService {
    pub(super) fn ensure_assignment_message(
        &self,
        assignment: &AssignmentRecord,
    ) -> Result<String, String> {
        let agent = self
            .event_store
            .core_agent_record(&assignment.agent_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("assignment agent '{}' was not found", assignment.agent_id))?;
        if let Some(message_id) = self
            .event_store
            .agent_assignment_admission_message_id(
                &agent.transcript_session_id,
                &assignment.assignment_id,
            )
            .map_err(|error| error.to_string())?
        {
            return Ok(message_id);
        }
        let source = assignment
            .requested_by_agent_id
            .as_deref()
            .map(|agent_id| self.event_store.core_agent_record(agent_id))
            .transpose()
            .map_err(|error| error.to_string())?
            .flatten();
        let (source_agent_id, source_name) = source.as_ref().map_or_else(
            || match assignment.kind {
                AssignmentKind::Operator => (
                    "operator:authenticated".to_owned(),
                    Some("Operator".to_owned()),
                ),
                AssignmentKind::Schedule => (
                    "engine:scheduler".to_owned(),
                    Some("Tron Scheduler".to_owned()),
                ),
                AssignmentKind::Instruction | AssignmentKind::Request => (
                    "engine:coordination".to_owned(),
                    Some("Tron Engine".to_owned()),
                ),
            },
            |source| (source.agent_id.clone(), Some(source.name.clone())),
        );
        let kind = match assignment.kind {
            AssignmentKind::Request => AgentMessageKind::Request,
            AssignmentKind::Instruction | AssignmentKind::Operator | AssignmentKind::Schedule => {
                AgentMessageKind::Instruction
            }
        };
        let authority = match assignment.kind {
            AssignmentKind::Request => AgentMessageAuthority::Peer,
            AssignmentKind::Operator => AgentMessageAuthority::Operator,
            AssignmentKind::Schedule => AgentMessageAuthority::Engine,
            AssignmentKind::Instruction => AgentMessageAuthority::Owner,
        };
        let text = if assignment
            .context
            .as_object()
            .is_some_and(serde_json::Map::is_empty)
        {
            assignment.task.clone()
        } else {
            format!(
                "{}\n\nEngine-authored assignment context:\n{}",
                assignment.task,
                serde_json::to_string(&assignment.context).map_err(|error| error.to_string())?
            )
        };
        let message_id = stable_id("agent_assignment_message", &assignment.assignment_id);
        let record = self
            .event_store
            .record_agent_message(&NewAgentMessageMetadata {
                idempotency_key: format!("core-assignment-message:{}", assignment.assignment_id),
                channel_id: channel_id(&source_agent_id, &agent.agent_id),
                channel_sequence: None,
                source_session_id: source.map(|source| source.transcript_session_id),
                target_agent_id: agent.agent_id,
                target_session_id: agent.transcript_session_id,
                trace_id: assignment.trace_id.clone(),
                autonomous_hop: 0,
                content: AgentMessageContent {
                    message_id,
                    source_agent_id,
                    source_name,
                    kind,
                    authority,
                    text,
                    assignment_id: Some(assignment.assignment_id.clone()),
                    reply_to: None,
                },
            })
            .map_err(|error| error.to_string())?;
        Ok(record.message_id)
    }

    /// Ensure every non-message wake has one durable Engine-authored message.
    /// Existing message wakes already point at canonical semantic metadata.
    pub(super) fn ensure_wake_message(&self, wake: &WakeIntentRecord) -> Result<String, String> {
        if wake.cause_kind == "message" {
            self.event_store
                .agent_message_metadata(&wake.cause_id)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("wake message '{}' was not found", wake.cause_id))?;
            return Ok(wake.cause_id.clone());
        }
        let target = self
            .event_store
            .core_agent_record(&wake.target_agent_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("wake agent '{}' was not found", wake.target_agent_id))?;
        let target_assignment = wake
            .target_assignment_id
            .as_deref()
            .map(|id| self.event_store.core_assignment_record(id))
            .transpose()
            .map_err(|error| error.to_string())?
            .flatten();
        let (source_agent_id, source_name, text) = if wake.cause_kind == "assignment_result" {
            let completed = self
                .event_store
                .core_assignment_record(&wake.cause_id)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("completed assignment '{}' was not found", wake.cause_id))?;
            let source = self
                .event_store
                .core_agent_record(&completed.agent_id)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("result agent '{}' was not found", completed.agent_id))?;
            (
                source.agent_id,
                Some(source.name),
                serde_json::to_string(&json!({
                    "assignmentId":completed.assignment_id,
                    "status":completed.status,
                    "resultReference":{
                        "kind":"agent_assignment",
                        "id":completed.assignment_id,
                    },
                }))
                .map_err(|error| error.to_string())?,
            )
        } else if wake.cause_kind == "wait_result" {
            let wait = self
                .event_store
                .coordination_wait(&wake.cause_id)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| format!("resolved wait '{}' was not found", wake.cause_id))?;
            let members = self
                .event_store
                .coordination_wait_members(&wake.cause_id)
                .map_err(|error| error.to_string())?;
            (
                target.agent_id.clone(),
                Some("Tron Engine".to_owned()),
                serde_json::to_string(&json!({
                    "waitId":wait.wait_id,
                    "mode":wait.mode,
                    "completed":members.into_iter().filter(|member| member.disposition == "satisfied").collect::<Vec<_>>(),
                }))
                .map_err(|error| error.to_string())?,
            )
        } else {
            (
                target.agent_id.clone(),
                Some("Tron Engine".to_owned()),
                serde_json::to_string(&json!({
                    "cause":wake.cause_kind,
                    "reference":wake.cause_id,
                }))
                .map_err(|error| error.to_string())?,
            )
        };
        let message_id = stable_id("agent_wake_message", &wake.wake_id);
        let trace_id = target_assignment.as_ref().map_or_else(
            || format!("agent-wake:{}", wake.wake_id),
            |assignment| assignment.trace_id.clone(),
        );
        let record = self
            .event_store
            .record_agent_message(&NewAgentMessageMetadata {
                idempotency_key: format!("core-wake-message:{}", wake.wake_id),
                channel_id: channel_id(&source_agent_id, &target.agent_id),
                channel_sequence: None,
                source_session_id: self
                    .event_store
                    .core_agent_record(&source_agent_id)
                    .map_err(|error| error.to_string())?
                    .map(|source| source.transcript_session_id),
                target_agent_id: target.agent_id,
                target_session_id: target.transcript_session_id,
                trace_id,
                autonomous_hop: 1,
                content: AgentMessageContent {
                    message_id,
                    source_agent_id,
                    source_name,
                    kind: AgentMessageKind::Result,
                    authority: AgentMessageAuthority::Engine,
                    text,
                    assignment_id: wake.target_assignment_id.clone(),
                    reply_to: None,
                },
            })
            .map_err(|error| error.to_string())?;
        Ok(record.message_id)
    }
}

fn channel_id(first: &str, second: &str) -> String {
    if first <= second {
        format!("agent_channel:{first}:{second}")
    } else {
        format!("agent_channel:{second}:{first}")
    }
}

fn stable_id(prefix: &str, value: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(prefix.as_bytes());
    digest.update(b"\0");
    digest.update(value.as_bytes());
    format!("{prefix}_{}", hex::encode(&digest.finalize()[..16]))
}

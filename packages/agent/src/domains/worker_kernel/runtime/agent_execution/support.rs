//! Content-free invalidations and deterministic outbox decoding helpers.
//!
//! Helpers remain private to reusable-agent execution.

use super::super::*;
use crate::shared::protocol::messages::{AgentMessageAuthority, AgentMessageKind};

impl WorkerRuntime {
    /// Invalidate both sides of a durable communication edge. Cross-root
    /// messages update the sender's outgoing history/contacts as well as the
    /// recipient's unread/current-work projection; same-root collaboration is
    /// emitted once.
    pub(super) async fn publish_agent_invalidation_for_roots(
        &self,
        topic: &str,
        source_root_session_id: Option<&str>,
        target_root_session_id: &str,
        payload: Value,
        trace_seed: &str,
    ) {
        if let Some(source_root_session_id) = source_root_session_id
            && source_root_session_id != target_root_session_id
        {
            self.publish_agent_invalidation(
                topic,
                source_root_session_id,
                payload.clone(),
                trace_seed,
            )
            .await;
        }
        self.publish_agent_invalidation(topic, target_root_session_id, payload, trace_seed)
            .await;
    }

    pub(super) async fn publish_agent_invalidation(
        &self,
        topic: &str,
        root_session_id: &str,
        mut payload: Value,
        trace_seed: &str,
    ) {
        if let Some(object) = payload.as_object_mut() {
            object.insert(
                "sessionId".to_owned(),
                Value::String(root_session_id.to_owned()),
            );
        }
        let _ = self
            .host
            .publish_stream_event(PublishStreamEvent {
                topic: topic.to_owned(),
                payload,
                visibility: StreamVisibility::System,
                session_id: Some(root_session_id.to_owned()),
                workspace_id: None,
                producer: "worker_kernel".to_owned(),
                trace_id: TraceId::new(format!("agent-{trace_seed}")).ok(),
                parent_invocation_id: None,
            })
            .await;
    }
}

pub(super) fn elapsed_rfc3339_seconds(start: &str) -> f64 {
    chrono::DateTime::parse_from_rfc3339(start)
        .ok()
        .and_then(|start| {
            chrono::Utc::now()
                .signed_duration_since(start.with_timezone(&chrono::Utc))
                .to_std()
                .ok()
        })
        .map_or(0.0, |duration| duration.as_secs_f64())
}

pub(super) fn elapsed_until_rfc3339_seconds(end: &str) -> f64 {
    chrono::DateTime::parse_from_rfc3339(end)
        .ok()
        .and_then(|end| {
            end.with_timezone(&chrono::Utc)
                .signed_duration_since(chrono::Utc::now())
                .to_std()
                .ok()
        })
        .map_or(0.0, |duration| duration.as_secs_f64())
}

pub(super) fn required_outbox_id<'a>(
    value: Option<&'a str>,
    label: &str,
) -> Result<&'a str, String> {
    value
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("agent outbox has no {label}"))
}

pub(super) fn required_payload_string(payload: &Value, key: &str) -> Result<String, String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("agent outbox payload requires {key}"))
}

pub(super) fn payload_u32(payload: &Value, key: &str) -> Result<u32, String> {
    payload
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| format!("agent outbox payload requires u32 {key}"))
}

pub(super) fn deterministic_message_id(key: &str) -> String {
    format!(
        "agent_message_{}",
        hex::encode(Sha256::digest(key.as_bytes()))
    )
}

pub(super) fn parse_outbox_message_kind(value: &str) -> Result<AgentMessageKind, String> {
    match value {
        "instruction" => Ok(AgentMessageKind::Instruction),
        "request" => Ok(AgentMessageKind::Request),
        "question" => Ok(AgentMessageKind::Question),
        "answer" => Ok(AgentMessageKind::Answer),
        "information" => Ok(AgentMessageKind::Information),
        "update" => Ok(AgentMessageKind::Update),
        "result" => Ok(AgentMessageKind::Result),
        other => Err(format!("unsupported agent message kind '{other}'")),
    }
}

pub(super) fn parse_outbox_message_authority(value: &str) -> Result<AgentMessageAuthority, String> {
    match value {
        "operator" => Ok(AgentMessageAuthority::Operator),
        "owner" => Ok(AgentMessageAuthority::Owner),
        "peer" => Ok(AgentMessageAuthority::Peer),
        "engine" => Ok(AgentMessageAuthority::Engine),
        other => Err(format!("unsupported agent message authority '{other}'")),
    }
}

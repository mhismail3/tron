//! Usage aggregation, relationship classification, cursors, and mutation validation.

use super::*;

impl WorkerRuntime {
    pub(super) fn assignment_usage_by_id<'a>(
        &self,
        agent: &AgentInstanceRecord,
        assignment_ids: impl IntoIterator<Item = &'a str>,
    ) -> Result<HashMap<String, UsageTotals>, String> {
        let requested = assignment_ids
            .into_iter()
            .map(ToOwned::to_owned)
            .collect::<HashSet<_>>();
        if requested.is_empty() {
            return Ok(HashMap::new());
        }
        let events = self
            .event_store
            .get_events_by_type(&agent.session_id, &["stream.turn_end"], None)
            .map_err(|error| error.to_string())?;
        let payloads = self
            .event_store
            .resolve_event_payloads(&events)
            .map_err(|error| error.to_string())?;
        let mut totals = HashMap::<String, UsageTotals>::new();
        for (event, payload) in events.iter().zip(payloads) {
            let Some(assignment_id) = payload.get("agentAssignmentId").and_then(Value::as_str)
            else {
                continue;
            };
            if requested.contains(assignment_id) {
                totals
                    .entry(assignment_id.to_owned())
                    .or_default()
                    .add_event(event);
            }
        }
        Ok(totals)
    }

    pub(super) fn subtree_usage_json(
        &self,
        root: &AgentInstanceRecord,
        agents: &HashMap<String, AgentInstanceRecord>,
    ) -> Result<Value, String> {
        let mut totals = UsageTotals::default();
        for agent in agents.values().filter(|candidate| {
            candidate.agent_id == root.agent_id
                || management_lineage_distance(candidate, &root.agent_id, agents).is_some()
        }) {
            if let Some(session) = self
                .event_store
                .get_session(&agent.session_id)
                .map_err(|error| error.to_string())?
            {
                totals.add_session(&session);
            }
        }
        Ok(totals.as_json())
    }
}

#[derive(Clone, Copy)]
pub(super) struct Relationship {
    pub(super) name: &'static str,
    pub(super) depth: usize,
}

#[derive(Default)]
pub(super) struct UsageTotals {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    cost: f64,
    wall_time: u64,
}

impl UsageTotals {
    fn add_event(&mut self, event: &crate::domains::session::event_store::EventRow) {
        self.input = self
            .input
            .saturating_add(nonnegative_u64(event.input_tokens));
        self.output = self
            .output
            .saturating_add(nonnegative_u64(event.output_tokens));
        self.cache_read = self
            .cache_read
            .saturating_add(nonnegative_u64(event.cache_read_tokens));
        self.cache_creation = self
            .cache_creation
            .saturating_add(nonnegative_u64(event.cache_creation_tokens));
        self.cost += event.cost.unwrap_or_default().max(0.0);
        self.wall_time = self
            .wall_time
            .saturating_add(nonnegative_u64(event.latency_ms));
    }

    fn add_session(&mut self, session: &crate::domains::session::event_store::SessionRow) {
        self.input = self
            .input
            .saturating_add(nonnegative_u64(Some(session.total_input_tokens)));
        self.output = self
            .output
            .saturating_add(nonnegative_u64(Some(session.total_output_tokens)));
        self.cache_read = self
            .cache_read
            .saturating_add(nonnegative_u64(Some(session.total_cache_read_tokens)));
        self.cache_creation = self
            .cache_creation
            .saturating_add(nonnegative_u64(Some(session.total_cache_creation_tokens)));
        self.cost += session.total_cost.max(0.0);
        if let (Ok(start), Ok(end)) = (
            chrono::DateTime::parse_from_rfc3339(&session.created_at),
            chrono::DateTime::parse_from_rfc3339(&session.last_activity_at),
        ) {
            self.wall_time = self.wall_time.saturating_add(
                u64::try_from((end - start).num_milliseconds().max(0)).unwrap_or_default(),
            );
        }
    }

    pub(super) fn as_json(&self) -> Value {
        json!({
            "inputTokens":self.input,
            "outputTokens":self.output,
            "cacheReadTokens":self.cache_read,
            "cacheCreationTokens":self.cache_creation,
            "cost":self.cost,
            "wallTimeMs":self.wall_time,
        })
    }
}

pub(super) fn relationship(
    owner: &AgentInstanceRecord,
    target: &AgentInstanceRecord,
    agents: &HashMap<String, AgentInstanceRecord>,
) -> Relationship {
    if owner.agent_id == target.agent_id {
        return Relationship {
            name: "self",
            depth: 0,
        };
    }
    if let Some(depth) = management_lineage_distance(target, &owner.agent_id, agents) {
        return Relationship {
            name: if depth == 1 { "child" } else { "descendant" },
            depth,
        };
    }
    if let Some(depth) = management_lineage_distance(owner, &target.agent_id, agents) {
        return Relationship {
            name: if depth == 1 { "parent" } else { "ancestor" },
            depth,
        };
    }
    // Promotion intentionally preserves immutable spawn lineage for audit but
    // detaches lifecycle ownership. Keep that former relationship visible in
    // Other Agents without allowing the old parent to reconstruct it as an
    // owned child or include it in subtree usage.
    if let Some(depth) = spawn_lineage_distance(target, &owner.agent_id, agents) {
        return Relationship {
            name: if depth == 1 {
                "promoted_child"
            } else {
                "promoted_descendant"
            },
            depth,
        };
    }
    if let Some(depth) = spawn_lineage_distance(owner, &target.agent_id, agents) {
        return Relationship {
            name: if depth == 1 {
                "former_parent"
            } else {
                "former_ancestor"
            },
            depth,
        };
    }
    Relationship {
        name: "peer",
        depth: 0,
    }
}

pub(super) fn management_lineage_distance(
    child: &AgentInstanceRecord,
    ancestor_id: &str,
    agents: &HashMap<String, AgentInstanceRecord>,
) -> Option<usize> {
    lineage_distance_by(child, ancestor_id, agents, |agent| {
        agent.management_owner_agent_id.as_deref()
    })
}

pub(super) fn spawn_lineage_distance(
    child: &AgentInstanceRecord,
    ancestor_id: &str,
    agents: &HashMap<String, AgentInstanceRecord>,
) -> Option<usize> {
    lineage_distance_by(child, ancestor_id, agents, |agent| {
        agent.spawned_by_agent_id.as_deref()
    })
}

pub(super) fn lineage_distance_by<'a>(
    child: &'a AgentInstanceRecord,
    ancestor_id: &str,
    agents: &'a HashMap<String, AgentInstanceRecord>,
    parent: impl Fn(&'a AgentInstanceRecord) -> Option<&'a str>,
) -> Option<usize> {
    let mut current = parent(child);
    let mut depth = 1;
    let mut visited = HashSet::new();
    while let Some(id) = current {
        if id == ancestor_id {
            return Some(depth);
        }
        if !visited.insert(id.to_owned()) {
            return None;
        }
        current = agents.get(id).and_then(&parent);
        depth += 1;
    }
    None
}

pub(super) fn lineage_json(
    agent: &AgentInstanceRecord,
    agents: &HashMap<String, AgentInstanceRecord>,
) -> Vec<Value> {
    let mut lineage = vec![json!({
        "agentId":agent.agent_id,
        "name":agent.name,
        "relationship":"self",
        "status":agent.state.as_str(),
    })];
    let mut current = agent.spawned_by_agent_id.as_deref();
    let mut visited = HashSet::new();
    while let Some(id) = current {
        if !visited.insert(id.to_owned()) {
            break;
        }
        let Some(parent) = agents.get(id) else { break };
        lineage.push(json!({
            "agentId":parent.agent_id,
            "name":parent.name,
            "relationship":"ancestor",
            "status":parent.state.as_str(),
        }));
        current = parent.spawned_by_agent_id.as_deref();
    }
    lineage.reverse();
    lineage
}

pub(super) fn client_message_summary(
    scope: &ClientAgentScope,
    agent: &AgentInstanceRecord,
    message: &AgentMessageMetadataRecord,
) -> Value {
    let incoming = message.target_agent_id == agent.agent_id;
    let other_id = if incoming {
        &message.source_agent_id
    } else {
        &message.target_agent_id
    };
    json!({
        "messageId":message.message_id,
        "direction":if incoming {"incoming"} else {"outgoing"},
        "kind":enum_json_name(&message.kind),
        "provenance":enum_json_name(&message.authority),
        "otherAgentId":other_id,
        "otherAgentName":scope.agents.get(other_id).map(|agent| agent.name.as_str()),
        "assignmentId":message.assignment_id,
        "replyTo":message.reply_to_message_id,
        "deliveryState":message_disposition_name(message.disposition),
        "preview":bounded_preview(&message.content.text, 240),
        "createdAt":message.created_at,
    })
}

pub(super) fn client_message_detail(
    scope: &ClientAgentScope,
    agent: &AgentInstanceRecord,
    message: &AgentMessageMetadataRecord,
) -> Value {
    let incoming = message.target_agent_id == agent.agent_id;
    json!({
        "messageId":message.message_id,
        "direction":if incoming {"incoming"} else {"outgoing"},
        "kind":enum_json_name(&message.kind),
        "provenance":enum_json_name(&message.authority),
        "sourceAgentId":message.source_agent_id,
        "sourceAgentName":scope.agents.get(&message.source_agent_id).map(|agent| agent.name.as_str()),
        "targetAgentId":message.target_agent_id,
        "targetAgentName":scope.agents.get(&message.target_agent_id).map(|agent| agent.name.as_str()),
        "assignmentId":message.assignment_id,
        "replyTo":message.reply_to_message_id,
        "deliveryState":message_disposition_name(message.disposition),
        "content":message.content.text,
        "createdAt":message.created_at,
        "deliveredAt":message.materialized_at,
        "observedAt":message.observed_at,
        "redeliveryCount":Value::Null,
    })
}

pub(super) fn assignment_result_summary(assignment: &AgentAssignmentRecord) -> Value {
    let preview = assignment
        .result_reference
        .as_ref()
        .and_then(|reference| reference.get("preview"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    json!({
        "kind":"agent_assignment",
        "status":assignment.status.as_str(),
        "preview":preview,
        "resultId":assignment.result_id,
        "workerInvocationId":Value::Null,
        "value":Value::Null,
    })
}

pub(super) fn session_usage_json(
    session: &crate::domains::session::event_store::SessionRow,
) -> Value {
    let mut totals = UsageTotals::default();
    totals.add_session(session);
    totals.as_json()
}

pub(super) fn allowed_action(action: &str, enabled: bool, reason: Option<&str>) -> Value {
    allowed_action_with_count(action, enabled, reason, None)
}

pub(super) fn allowed_action_with_count(
    action: &str,
    enabled: bool,
    reason: Option<&str>,
    affected_count: Option<u64>,
) -> Value {
    let disabled_reason = if enabled {
        None
    } else {
        Some(
            reason
                .filter(|reason| !reason.trim().is_empty())
                .unwrap_or("This action is unavailable in the current agent state"),
        )
    };
    json!({
        "action":action,
        "enabled":enabled,
        "disabledReason":disabled_reason,
        "affectedCount":affected_count,
    })
}

pub(super) fn message_disposition_name(value: AgentMessageDisposition) -> &'static str {
    match value {
        AgentMessageDisposition::Pending => "pending",
        AgentMessageDisposition::Materialized => "delivered",
        AgentMessageDisposition::Observed => "observed",
        AgentMessageDisposition::Cancelled => "cancelled",
    }
}

pub(super) fn enum_json_name<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|value| value.as_str().map(ToOwned::to_owned))
        .unwrap_or_else(|| "unknown".to_owned())
}

pub(super) fn required_client_string(payload: &Value, key: &str) -> Result<String, String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("agent client operation requires {key}"))
}

pub(super) fn client_limit(payload: &Value, default: usize) -> usize {
    payload
        .get("limit")
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .unwrap_or(default)
        .clamp(1, MAX_CLIENT_PAGE)
}

pub(super) fn decode_offset_cursor(cursor: Option<&str>) -> Result<usize, String> {
    let Some(cursor) = cursor else { return Ok(0) };
    cursor
        .strip_prefix("offset:")
        .and_then(|value| value.parse::<usize>().ok())
        .ok_or_else(|| "agent page cursor is invalid or stale".to_owned())
}

pub(super) fn encode_message_cursor(created_at: &str, message_id: &str) -> String {
    format!("{created_at}|{message_id}")
}

pub(super) fn decode_message_cursor(
    cursor: Option<&str>,
) -> Result<Option<(String, String)>, String> {
    let Some(cursor) = cursor else {
        return Ok(None);
    };
    let (created_at, message_id) = cursor
        .rsplit_once('|')
        .ok_or_else(|| "agent message cursor is invalid or stale".to_owned())?;
    if created_at.is_empty() || message_id.is_empty() {
        return Err("agent message cursor is invalid or stale".to_owned());
    }
    Ok(Some((created_at.to_owned(), message_id.to_owned())))
}

pub(super) fn bounded_preview(value: &str, limit: usize) -> String {
    crate::shared::foundation::text::truncate_str(value, limit).to_owned()
}

pub(super) fn string_values(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(ToOwned::to_owned)
        .collect()
}

pub(super) fn nonnegative_u64(value: Option<i64>) -> u64 {
    u64::try_from(value.unwrap_or_default().max(0)).unwrap_or_default()
}

pub(super) fn limit_unit(name: &str) -> Option<&'static str> {
    let lower = name.to_ascii_lowercase();
    if lower.contains("second") {
        Some("seconds")
    } else if lower.contains("turn") {
        Some("turns")
    } else if lower.contains("child") || lower.contains("queue") {
        Some("count")
    } else {
        None
    }
}

pub(super) fn parse_client_management_capability(
    value: &str,
) -> Result<AgentManagementCapability, String> {
    match value {
        "assign" => Ok(AgentManagementCapability::Assign),
        "cancel" => Ok(AgentManagementCapability::Cancel),
        "configure" => Ok(AgentManagementCapability::Configure),
        "close" => Ok(AgentManagementCapability::Close),
        other => Err(format!("unsupported management right '{other}'")),
    }
}

pub(super) fn ensure_json_subset(
    candidate: &Value,
    ceiling: &Value,
    label: &str,
) -> Result<(), String> {
    let candidate = candidate
        .as_array()
        .ok_or_else(|| format!("agent {label} must be an array"))?;
    let ceiling = ceiling
        .as_array()
        .ok_or_else(|| format!("current agent {label} is invalid"))?;
    if candidate.iter().any(|value| !ceiling.contains(value)) {
        return Err(format!("agent {label} may only be tightened"));
    }
    Ok(())
}

pub(super) fn ensure_limit_tightening(candidate: &Value, ceiling: &Value) -> Result<(), String> {
    let candidate = candidate
        .as_object()
        .ok_or_else(|| "agent limits must be an object".to_owned())?;
    let ceiling = ceiling
        .as_object()
        .ok_or_else(|| "current agent limits are invalid".to_owned())?;
    for (key, value) in candidate {
        let requested = value
            .as_u64()
            .ok_or_else(|| format!("agent limit '{key}' must be a positive integer"))?;
        let current = ceiling
            .get(key)
            .and_then(Value::as_u64)
            .ok_or_else(|| format!("agent limit '{key}' is not configurable"))?;
        if requested == 0 || requested > current {
            return Err(format!("agent limit '{key}' may only be tightened"));
        }
    }
    Ok(())
}

pub(super) fn normalize_client_limits(candidate: &Value, ceiling: &Value) -> Result<Value, String> {
    let input = candidate
        .as_object()
        .ok_or_else(|| "agent limits must be an object".to_owned())?;
    let mut normalized = ceiling
        .as_object()
        .cloned()
        .ok_or_else(|| "current agent limits are invalid".to_owned())?;
    for (key, value) in input {
        match key.as_str() {
            "maxMinutes" => {
                let minutes = value
                    .as_u64()
                    .filter(|value| *value > 0)
                    .ok_or_else(|| "maxMinutes must be a positive integer".to_owned())?;
                normalized.insert(
                    "maxAssignmentSeconds".to_owned(),
                    Value::from(
                        minutes.checked_mul(60).ok_or_else(|| {
                            "maxMinutes exceeds the supported duration".to_owned()
                        })?,
                    ),
                );
            }
            "maxTurns" => {
                normalized.insert("maxAssignmentTurns".to_owned(), value.clone());
            }
            other => return Err(format!("agent limit '{other}' is not configurable")),
        }
    }
    Ok(Value::Object(normalized))
}

pub(super) fn assignment_deadline(limits: &Value) -> Option<String> {
    limits
        .get("maxAssignmentSeconds")
        .and_then(Value::as_u64)
        .and_then(|seconds| chrono::Duration::try_seconds(i64::try_from(seconds).ok()?))
        .map(|duration| (chrono::Utc::now() + duration).to_rfc3339())
}

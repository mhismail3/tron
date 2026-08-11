//! Replay equality, authority limits, and bounded input validation.

use super::*;

pub(super) fn validate_spawn_replay(
    agent: &AgentRecord,
    assignment: &AssignmentRecord,
    request: &SpawnAgent,
) -> Result<()> {
    if agent.parent_agent_id.as_deref() != Some(request.parent_agent_id.as_str())
        || agent.name != request.name
        || assignment.parent_assignment_id != request.parent_assignment_id
        || assignment.kind != AssignmentKind::Instruction
        || assignment.task != request.task
        || assignment.context != request.context
        || assignment.autonomous_hop != request.autonomous_hop
        || assignment.deadline_at != request.deadline_at
        || agent.defaults.reasoning_level != request.defaults.reasoning_level
        || agent.defaults.capability_grant != request.defaults.capability_grant
        || agent.defaults.write_scopes != request.defaults.write_scopes
        || agent.defaults.limits != request.defaults.limits
        || request
            .defaults
            .model
            .as_ref()
            .is_some_and(|model| agent.defaults.model.as_ref() != Some(model))
    {
        return Err(EventStoreError::InvalidOperation(
            "agent spawn idempotency conflict".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn validate_assignment_replay(
    assignment: &AssignmentRecord,
    request: &NewAssignment,
) -> Result<()> {
    if assignment.agent_id != request.agent_id
        || assignment.requested_by_agent_id != request.requested_by_agent_id
        || assignment.parent_assignment_id != request.parent_assignment_id
        || assignment.retry_of_assignment_id != request.retry_of_assignment_id
        || assignment.kind != request.kind
        || assignment.task != request.task
        || assignment.context != request.context
        || assignment.autonomous_hop != request.autonomous_hop
        || assignment.deadline_at != request.deadline_at
        || request
            .trace_id
            .as_ref()
            .is_some_and(|trace_id| assignment.trace_id != *trace_id)
        || request
            .model
            .as_ref()
            .is_some_and(|model| assignment.model.as_ref() != Some(model))
        || request
            .reasoning_level
            .as_ref()
            .is_some_and(|level| assignment.reasoning_level.as_ref() != Some(level))
        || request
            .capability_grant
            .as_ref()
            .is_some_and(|grant| assignment.capability_snapshot != *grant)
        || request
            .write_scopes
            .as_ref()
            .is_some_and(|scopes| assignment.write_scopes_snapshot != *scopes)
        || request
            .limits
            .as_ref()
            .is_some_and(|limits| assignment.limits_snapshot != *limits)
    {
        return Err(EventStoreError::InvalidOperation(
            "assignment admission idempotency conflict".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn validate_completion_transition(
    from: AssignmentStatus,
    to: AssignmentStatus,
) -> Result<()> {
    let allowed = match to {
        AssignmentStatus::Completed | AssignmentStatus::Failed => {
            matches!(from, AssignmentStatus::Running | AssignmentStatus::Waiting)
        }
        AssignmentStatus::Declined => from == AssignmentStatus::Offered,
        AssignmentStatus::Cancelled => !from.is_terminal(),
        AssignmentStatus::TimedOut => matches!(
            from,
            AssignmentStatus::Queued | AssignmentStatus::Running | AssignmentStatus::Waiting
        ),
        AssignmentStatus::Expired => {
            matches!(from, AssignmentStatus::Offered | AssignmentStatus::Queued)
        }
        _ => false,
    };
    if !allowed {
        return Err(EventStoreError::InvalidOperation(format!(
            "cannot complete assignment from {} as {}",
            from.as_str(),
            to.as_str()
        )));
    }
    Ok(())
}

pub(super) fn message_priority(authority: AgentMessageAuthority, kind: MessageKind) -> u8 {
    match (authority, kind) {
        (AgentMessageAuthority::Operator, _) => 10,
        (AgentMessageAuthority::Engine, _) => 30,
        (AgentMessageAuthority::Owner, MessageKind::Instruction) => 20,
        (_, MessageKind::Answer) => 25,
        (_, MessageKind::Question | MessageKind::Request) => 30,
        (_, MessageKind::Instruction | MessageKind::Update) => 35,
        (_, MessageKind::Information) => 80,
    }
}

pub(super) fn validate_new_assignment(request: &NewAssignment) -> Result<()> {
    validate_admission_key(&request.admission_key)?;
    validate_identifier("assignment agent id", &request.agent_id)?;
    if let Some(requester) = request.requested_by_agent_id.as_deref() {
        validate_identifier("assignment requester agent id", requester)?;
    }
    if let Some(parent) = request.parent_assignment_id.as_deref() {
        validate_identifier("parent assignment id", parent)?;
    }
    if let Some(retry) = request.retry_of_assignment_id.as_deref() {
        validate_identifier("retry assignment id", retry)?;
    }
    if let Some(trace_id) = request.trace_id.as_deref() {
        validate_identifier("assignment trace id", trace_id)?;
    }
    validate_task(&request.task)?;
    validate_json_size("assignment context", &request.context, MAX_CONTEXT_BYTES)?;
    if let Some(grant) = request.capability_grant.as_ref() {
        validate_json_size("assignment capability grant", grant, MAX_CONTEXT_BYTES)?;
    }
    if let Some(scopes) = request.write_scopes.as_ref() {
        validate_write_scopes(scopes)?;
    }
    if let Some(limits) = request.limits.as_ref() {
        validate_limits(limits)?;
    }
    validate_optional_timestamp("assignment deadline", request.deadline_at.as_deref())
}

pub(super) fn validate_defaults(defaults: &AgentDefaults) -> Result<()> {
    validate_json_size(
        "agent capability grant",
        &defaults.capability_grant,
        MAX_CONTEXT_BYTES,
    )?;
    validate_write_scopes(&defaults.write_scopes)?;
    validate_limits(&defaults.limits)
}

pub(super) fn validate_limits(limits: &AssignmentLimits) -> Result<()> {
    if limits.max_turns == 0
        || limits.max_turns > HARD_MAX_TURNS
        || limits.timeout_seconds == 0
        || limits.timeout_seconds > HARD_TIMEOUT_SECONDS
        || limits.max_queued_assignments == 0
        || limits.max_queued_assignments > HARD_MAX_QUEUED_ASSIGNMENTS
    {
        return Err(EventStoreError::InvalidOperation(
            "agent limits exceed the supported hard ceilings".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn validate_write_scopes(scopes: &[String]) -> Result<()> {
    if scopes.len() > MAX_WRITE_SCOPES {
        return Err(EventStoreError::InvalidOperation(format!(
            "agent configuration exceeds {MAX_WRITE_SCOPES} write scopes"
        )));
    }
    let mut unique = HashSet::new();
    for scope in scopes {
        validate_state_component("write scope", scope, 1_024)?;
        if !unique.insert(scope) {
            return Err(EventStoreError::InvalidOperation(
                "agent write scopes contain duplicates".to_owned(),
            ));
        }
    }
    Ok(())
}

pub(super) fn validate_name(name: &str) -> Result<()> {
    validate_bounded_text("agent name", name, MAX_NAME_BYTES)
}

pub(super) fn validate_task(task: &str) -> Result<()> {
    validate_bounded_text("assignment task", task, MAX_TASK_BYTES)
}

pub(super) fn validate_admission_key(value: &str) -> Result<()> {
    validate_identifier("coordination idempotency key", value)
}

pub(super) fn validate_identifier(label: &str, value: &str) -> Result<()> {
    validate_state_component(label, value, MAX_ID_BYTES)
}

pub(super) fn validate_state_component(label: &str, value: &str, max_bytes: usize) -> Result<()> {
    if value.trim().is_empty() || value.len() > max_bytes || value.chars().any(char::is_control) {
        return Err(EventStoreError::InvalidOperation(format!(
            "{label} must contain 1..={max_bytes} bytes and no control characters"
        )));
    }
    Ok(())
}

pub(super) fn validate_bounded_text(label: &str, value: &str, max_bytes: usize) -> Result<()> {
    if value.trim().is_empty() || value.len() > max_bytes {
        return Err(EventStoreError::InvalidOperation(format!(
            "{label} must contain 1..={max_bytes} UTF-8 bytes"
        )));
    }
    Ok(())
}

pub(super) fn validate_json_size(label: &str, value: &Value, max_bytes: usize) -> Result<()> {
    let size = serde_json::to_vec(value)?.len();
    if size > max_bytes {
        return Err(EventStoreError::InvalidOperation(format!(
            "{label} exceeds {max_bytes} bytes"
        )));
    }
    Ok(())
}

pub(super) fn validate_optional_timestamp(label: &str, value: Option<&str>) -> Result<()> {
    if let Some(value) = value
        && chrono::DateTime::parse_from_rfc3339(value).is_err()
    {
        return Err(EventStoreError::InvalidOperation(format!(
            "{label} must be an RFC 3339 instant"
        )));
    }
    Ok(())
}

pub(super) fn stable_id(prefix: &str, components: &[&str]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(prefix.as_bytes());
    for component in components {
        hasher.update([0]);
        hasher.update(component.len().to_be_bytes());
        hasher.update(component.as_bytes());
    }
    format!("{prefix}_{:x}", hasher.finalize())
}

pub(super) fn hex_sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

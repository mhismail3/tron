//! Validation, serialization, metrics, and shared SQL projections.
//!
//! These helpers are visible only inside the reusable-agent persistence concern.

use super::*;

pub(super) const MAX_TASK_BYTES: usize = 40_000;
pub(super) const MAX_MESSAGE_ENVELOPE_BYTES: usize = 48_000;
pub(super) const MAX_NAME_BYTES: usize = 160;
pub(super) const MAX_ERROR_BYTES: usize = 4_096;
pub(super) const MAX_AGENT_OUTBOX_ATTEMPTS: u32 = 10;
pub(super) const AGENT_OUTBOX_RETRY_BASE_SECONDS: i64 = 2;
pub(super) const AGENT_OUTBOX_RETRY_CAP_SECONDS: i64 = 300;
pub(super) const WORKSPACE_PROCESS_GATE_DIRECTORY: &str = "workspace-process-gates";

pub(super) fn sqlite_contains_pattern(value: &str) -> String {
    let escaped = value
        .to_ascii_lowercase()
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    if escaped.is_empty() {
        String::new()
    } else {
        format!("%{escaped}%")
    }
}

pub(super) const AGENT_COLUMNS: &str = "
    agent_id,session_id,root_session_id,workspace_id,spawned_by_agent_id,
    management_owner_agent_id,kind,role_id,role_version,name,visibility,state,
    default_model,default_reasoning_level,tool_grant_json,write_scopes_json,
    limits_json,created_at,updated_at,closed_at
";
pub(super) const ASSIGNMENT_COLUMNS: &str = "
    assignment_id,execution_id,agent_id,requester_agent_id,delegator_agent_id,
    kind,status,admission_key,queue_ordinal,task,context_json,model,reasoning_level,
    authority_snapshot_json,resource_snapshot_json,write_scopes_snapshot_json,
    limits_snapshot_json,retry_of_assignment_id,result_id,result_reference_json,error,
    deadline_at,created_at,accepted_at,started_at,completed_at,updated_at
";
pub(super) const EXECUTION_COLUMNS: &str = "
    execution_id,kind,parent_execution_id,owner_agent_id,root_session_id,
    trace_id,causal_depth,child_slot,worker_invocation_id,assignment_id,created_at
";
pub(super) const COORDINATION_TRACE_STATE_COLUMNS: &str = "
    trace_id,root_session_id,state,reason,created_at,updated_at,paused_at,resumed_at
";
pub(super) const ATTEMPT_COLUMNS: &str = "
    attempt_id,assignment_id,attempt_number,status,run_id,baseline_event_sequence,
    started_at,completed_at,error
";
pub(super) const OUTBOX_COLUMNS: &str = "
    outbox_id,deduplication_key,kind,agent_id,assignment_id,execution_id,
    payload_json,disposition,attempts,last_error,next_attempt_at,created_at,processed_at
";
pub(super) const GRANT_COLUMNS: &str = "
    grant_id,idempotency_key,target_agent_id,grantee_agent_id,granted_by_agent_id,
    capability,created_at,revoked_at
";
pub(super) const CLAIM_COLUMNS: &str = "
    claim_id,idempotency_key,execution_id,agent_id,holder_session_id,workspace_id,
    kind,canonical_scope,state,requested_at,acquired_at,released_at,process_id,
    process_identity
";

pub(super) fn record_agent_assignment_admission_metrics(assignment: &AgentAssignmentRecord) {
    metrics::counter!(
        "agent_coordination_assignment_admissions_total",
        "kind" => assignment.kind.as_str(),
        "initial_state" => assignment.status.as_str()
    )
    .increment(1);
    metrics::counter!(
        "agent_coordination_assignment_states_total",
        "kind" => assignment.kind.as_str(),
        "state" => assignment.status.as_str()
    )
    .increment(1);
}

pub(super) fn record_agent_assignment_transition_metrics(
    previous: &AgentAssignmentRecord,
    current: &AgentAssignmentRecord,
) {
    metrics::counter!(
        "agent_coordination_assignment_states_total",
        "kind" => current.kind.as_str(),
        "state" => current.status.as_str()
    )
    .increment(1);
    if current.status == AgentAssignmentStatus::Running
        && previous.started_at.is_none()
        && let Some(seconds) = elapsed_timestamp_seconds(
            &current.created_at,
            current.started_at.as_deref().unwrap_or(&current.updated_at),
        )
    {
        metrics::histogram!(
            "agent_coordination_assignment_queue_seconds",
            "kind" => current.kind.as_str()
        )
        .record(seconds);
    }
    if current.status.is_terminal()
        && let Some(seconds) = elapsed_timestamp_seconds(
            current.started_at.as_deref().unwrap_or(&current.created_at),
            current
                .completed_at
                .as_deref()
                .unwrap_or(&current.updated_at),
        )
    {
        metrics::histogram!(
            "agent_coordination_assignment_duration_seconds",
            "kind" => current.kind.as_str(),
            "outcome" => current.status.as_str()
        )
        .record(seconds);
    }
    if current.status == AgentAssignmentStatus::Cancelled {
        metrics::counter!(
            "agent_coordination_cancellations_total",
            "kind" => current.kind.as_str(),
            "from_state" => previous.status.as_str()
        )
        .increment(1);
    }
}

pub(super) fn elapsed_timestamp_seconds(start: &str, end: &str) -> Option<f64> {
    let start = chrono::DateTime::parse_from_rfc3339(start).ok()?;
    let end = chrono::DateTime::parse_from_rfc3339(end).ok()?;
    end.signed_duration_since(start)
        .to_std()
        .ok()
        .map(|duration| duration.as_secs_f64())
}

pub(super) fn coordination_outbox_timestamp(value: chrono::DateTime<chrono::Utc>) -> String {
    value.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

pub(super) fn bounded_agent_error(value: &str) -> String {
    if value.len() <= MAX_ERROR_BYTES {
        return value.to_owned();
    }
    let mut end = MAX_ERROR_BYTES;
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    value[..end].to_owned()
}

/// Terminally reject one exhausted cross-store effect and commit the semantic
/// compensation that keeps admitted coordination inspectable. This is one
/// `workers.sqlite` transaction: a crash can retain the claimed row for
/// restart replay, but can never publish only the rejection while omitting its
/// failed assignment/result or deterministic operator Attention evidence.
pub(super) fn reject_agent_outbox_with_compensation_in_tx(
    transaction: &Transaction<'_>,
    row: &AgentOutboxRecord,
    error: &str,
    attempts: u32,
    processed_at: &str,
) -> Result<(), String> {
    let compensation =
        compensate_rejected_assignment_admission_in_tx(transaction, row, error, processed_at)?;
    let message_purpose = row.payload.get("messagePurpose").and_then(Value::as_str);
    let attention = json!({
        "status":"failed",
        "phase":"agent_coordination_outbox_import",
        "code":"AGENT_COORDINATION_DELIVERY_FAILED",
        "outboxId":row.outbox_id,
        "outboxKind":row.kind.as_str(),
        "agentId":row.agent_id,
        "assignmentId":row.assignment_id,
        "executionId":row.execution_id,
        "messagePurpose":message_purpose,
        "attempts":attempts,
        "compensation":compensation,
        "error":error,
    });
    transaction
        .execute(
            "INSERT OR IGNORE INTO worker_inbox(
                inbox_id,invocation_id,worker_id,severity,result_json,created_at
             ) VALUES (?1,?2,'agent-coordination','error',?3,?4)",
            params![
                format!("agent_coordination_outbox_attention_{}", row.outbox_id),
                format!("agent_coordination_outbox_{}", row.outbox_id),
                encode_json(&attention)?,
                processed_at,
            ],
        )
        .map_err(|cause| format!("record rejected coordination outbox Attention: {cause}"))?;
    let changed = transaction
        .execute(
            "UPDATE agent_outbox
             SET disposition='rejected',processed_at=?2,last_error=?3,
                 next_attempt_at=?2
             WHERE outbox_id=?1 AND disposition='importing'",
            params![row.outbox_id, processed_at, error],
        )
        .map_err(|cause| format!("reject exhausted agent outbox row: {cause}"))?;
    if changed != 1 {
        return Err("claimed agent outbox changed during terminal compensation".to_owned());
    }
    Ok(())
}

pub(super) fn compensate_rejected_assignment_admission_in_tx(
    transaction: &Transaction<'_>,
    row: &AgentOutboxRecord,
    error: &str,
    processed_at: &str,
) -> Result<&'static str, String> {
    let assignment_admission = row.kind == AgentOutboxKind::Provision
        || (row.kind == AgentOutboxKind::Message
            && row.payload.get("messagePurpose").and_then(Value::as_str)
                == Some("assignment_admission"));
    if !assignment_admission {
        return Ok("operator_attention_recorded");
    }
    let Some(assignment_id) = row.assignment_id.as_deref() else {
        return Ok("missing_assignment_attention_recorded");
    };
    let Some(mut assignment) = query_assignment(transaction, assignment_id)? else {
        return Ok("missing_assignment_attention_recorded");
    };
    let failure = bounded_agent_error(&format!(
        "coordination {} delivery failed after {MAX_AGENT_OUTBOX_ATTEMPTS} attempts: {error}",
        row.kind.as_str()
    ));
    let admission_was_failed = matches!(
        assignment.status,
        AgentAssignmentStatus::Offered
            | AgentAssignmentStatus::Accepted
            | AgentAssignmentStatus::Queued
    );
    if admission_was_failed {
        let previous = assignment.status;
        let changed = transaction
            .execute(
                "UPDATE agent_assignments
                 SET status='failed',completed_at=?2,result_id=NULL,result_json=NULL,
                     result_reference_json=NULL,error=?3,updated_at=?2
                 WHERE assignment_id=?1 AND status IN ('offered','accepted','queued')",
                params![assignment.assignment_id, processed_at, failure],
            )
            .map_err(|cause| format!("fail rejected coordination admission: {cause}"))?;
        if changed != 1 {
            return Err("coordination admission changed during poison compensation".to_owned());
        }
        transaction
            .execute(
                "UPDATE agent_assignment_attempts
                 SET status='interrupted',completed_at=?2,error=COALESCE(error,?3)
                 WHERE assignment_id=?1 AND status='running'",
                params![assignment.assignment_id, processed_at, failure],
            )
            .map_err(|cause| format!("interrupt rejected coordination admission: {cause}"))?;
        if row.kind == AgentOutboxKind::Provision {
            transaction
                .execute(
                    "UPDATE agent_instances
                     SET state='closed',closed_at=COALESCE(closed_at,?2),updated_at=?2
                     WHERE agent_id=?1 AND state='provisioning'",
                    params![assignment.agent_id, processed_at],
                )
                .map_err(|cause| format!("close rejected provisioned agent: {cause}"))?;
        }
        update_agent_state_for_assignment(
            transaction,
            &assignment.agent_id,
            AgentAssignmentStatus::Failed,
            processed_at,
        )?;
        append_execution_event_in_tx(
            transaction,
            &assignment.execution_id,
            AgentAssignmentStatus::Failed.as_str(),
            &json!({
                "from":previous.as_str(),
                "to":AgentAssignmentStatus::Failed.as_str(),
                "reason":"coordination_outbox_rejected",
                "outboxId":row.outbox_id,
                "outboxKind":row.kind.as_str(),
            }),
            processed_at,
        )?;
        assignment = query_assignment(transaction, assignment_id)?
            .ok_or_else(|| "compensated agent assignment disappeared".to_owned())?;
    } else if row.kind == AgentOutboxKind::Provision && assignment.status.is_terminal() {
        transaction
            .execute(
                "UPDATE agent_instances
                 SET state='closed',closed_at=COALESCE(closed_at,?2),updated_at=?2
                 WHERE agent_id=?1 AND state='provisioning'",
                params![assignment.agent_id, processed_at],
            )
            .map_err(|cause| format!("close terminal rejected provisioned agent: {cause}"))?;
    }
    if assignment.status.is_terminal() {
        ensure_agent_assignment_result_outbox_in_tx(transaction, &assignment, processed_at)?;
        return Ok(if admission_was_failed {
            "assignment_failed_result_queued"
        } else {
            "terminal_assignment_result_retained"
        });
    }
    Ok("delivery_already_advanced_attention_recorded")
}

pub(super) fn ensure_agent_assignment_result_outbox_in_tx(
    transaction: &Transaction<'_>,
    assignment: &AgentAssignmentRecord,
    created_at: &str,
) -> Result<(), String> {
    let execution = query_execution(transaction, &assignment.execution_id)?
        .ok_or_else(|| "compensated assignment lost its execution node".to_owned())?;
    transaction
        .execute(
            "INSERT OR IGNORE INTO agent_outbox(
                outbox_id,deduplication_key,kind,agent_id,assignment_id,
                execution_id,payload_json,created_at
             ) VALUES (?1,?2,'result',?3,?4,?5,?6,?7)",
            params![
                format!("agent_outbox_compensation_{}", assignment.assignment_id),
                format!("assignment-result:{}", assignment.assignment_id),
                assignment.agent_id,
                assignment.assignment_id,
                assignment.execution_id,
                encode_json(&json!({
                    "agentId":assignment.agent_id,
                    "assignmentId":assignment.assignment_id,
                    "executionId":assignment.execution_id,
                    "traceId":execution.trace_id,
                    "status":assignment.status.as_str(),
                    "resultId":assignment.result_id,
                    "resultReference":assignment.result_reference,
                    "error":assignment.error,
                }))?,
                created_at,
            ],
        )
        .map(|_| ())
        .map_err(|cause| format!("retain compensated agent result delivery: {cause}"))
}

pub(super) fn validate_name(value: &str) -> Result<(), String> {
    if value.trim().is_empty()
        || value.as_bytes().len() > MAX_NAME_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(format!(
            "agent name must contain 1..={MAX_NAME_BYTES} UTF-8 bytes and no control characters"
        ));
    }
    Ok(())
}

pub(super) fn validate_task(value: &str) -> Result<(), String> {
    if value.trim().is_empty() || value.as_bytes().len() > MAX_TASK_BYTES {
        return Err(format!(
            "agent task must contain 1..={MAX_TASK_BYTES} UTF-8 bytes"
        ));
    }
    Ok(())
}

pub(super) fn validate_admission(request: &NewAgentAdmission) -> Result<(), String> {
    validate_runtime_identifier(&request.admission_key, "agent admission key", 256)?;
    validate_runtime_identifier(&request.root_session_id, "root session id", 256)?;
    validate_runtime_identifier(&request.workspace_id, "workspace id", 256)?;
    validate_runtime_identifier(&request.trace_id, "agent trace id", 256)?;
    validate_name(&request.name)?;
    if request.task.trim().is_empty() || request.task.as_bytes().len() > MAX_TASK_BYTES {
        return Err(format!(
            "agent task must contain 1..={MAX_TASK_BYTES} UTF-8 bytes"
        ));
    }
    if request.assignment_kind != AgentAssignmentKind::Instruction {
        return Err("new reusable agents require an accepted instruction assignment".to_owned());
    }
    match request.kind {
        AgentInstanceKind::Role if request.role_id.is_none() || request.role_version.is_none() => {
            return Err("named agent roles require a role id and immutable version".to_owned());
        }
        AgentInstanceKind::Role => {}
        _ if request.role_id.is_some() || request.role_version.is_some() => {
            return Err("only named agent roles may pin a role id/version".to_owned());
        }
        _ => {}
    }
    if request.causal_depth > 16 {
        return Err("agent causal depth exceeds the hard ceiling of 16".to_owned());
    }
    validate_admission_ceilings(
        request.max_active_children,
        request.max_child_executions,
        request.max_execution_nodes,
        request.max_causal_depth,
        None,
    )?;
    if let Some(deadline) = request.deadline_at.as_deref() {
        chrono::DateTime::parse_from_rfc3339(deadline)
            .map_err(|_| "agent deadline must be an RFC 3339 timestamp".to_owned())?;
    }
    for (name, value) in [
        ("context", &request.context),
        ("tool grant", &request.tool_grant),
        ("resource snapshot", &request.resource_snapshot),
        ("limits", &request.limits),
    ] {
        if !value.is_object() && !value.is_array() {
            return Err(format!("agent {name} must be a JSON object or array"));
        }
    }
    validate_write_scope_snapshot(&request.write_scopes, "agent write scopes")?;
    Ok(())
}

pub(super) fn validate_existing_assignment(request: &NewAgentAssignment) -> Result<(), String> {
    validate_runtime_identifier(&request.admission_key, "agent assignment key", 256)?;
    validate_runtime_identifier(&request.agent_id, "agent id", 256)?;
    validate_runtime_identifier(&request.trace_id, "agent trace id", 256)?;
    if request.task.trim().is_empty() || request.task.as_bytes().len() > MAX_TASK_BYTES {
        return Err(format!(
            "agent task must contain 1..={MAX_TASK_BYTES} UTF-8 bytes"
        ));
    }
    if request.causal_depth > 16 {
        return Err("agent causal depth exceeds the hard ceiling of 16".to_owned());
    }
    validate_admission_ceilings(
        request.max_active_children,
        request.max_child_executions,
        request.max_execution_nodes,
        request.max_causal_depth,
        Some(request.max_queued_assignments),
    )?;
    if request.offered != (request.kind == AgentAssignmentKind::Request) {
        return Err("only peer request assignments use the offered state".to_owned());
    }
    validate_assignment_message(request)?;
    if let Some(deadline) = request.deadline_at.as_deref() {
        chrono::DateTime::parse_from_rfc3339(deadline)
            .map_err(|_| "agent deadline must be an RFC 3339 timestamp".to_owned())?;
    }
    for (name, value) in [
        ("context", &request.context),
        ("authority snapshot", &request.authority_snapshot),
        ("resource snapshot", &request.resource_snapshot),
        ("limits snapshot", &request.limits_snapshot),
    ] {
        if !value.is_object() && !value.is_array() {
            return Err(format!(
                "agent assignment {name} must be a JSON object or array"
            ));
        }
    }
    validate_write_scope_snapshot(
        &request.write_scopes_snapshot,
        "agent assignment write scopes",
    )?;
    Ok(())
}

pub(super) fn validate_write_scope_snapshot(value: &Value, label: &str) -> Result<(), String> {
    let scopes = value
        .as_array()
        .ok_or_else(|| format!("{label} must be an array of canonical relative prefixes"))?;
    if scopes.len() > 64 {
        return Err(format!("{label} exceeds the 64-prefix ceiling"));
    }
    let mut accepted = Vec::<&str>::with_capacity(scopes.len());
    for scope in scopes {
        let scope = scope
            .as_str()
            .ok_or_else(|| format!("{label} entries must be strings"))?;
        if scope != "." {
            let path = Path::new(scope);
            let normalized = path
                .components()
                .map(|component| component.as_os_str().to_string_lossy())
                .collect::<Vec<_>>()
                .join("/");
            if scope.is_empty()
                || scope.contains('\0')
                || scope.contains('\\')
                || path.is_absolute()
                || path
                    .components()
                    .any(|component| !matches!(component, Component::Normal(_)))
                || normalized != scope
            {
                return Err(format!(
                    "{label} entry '{scope}' is not a canonical workspace-relative prefix"
                ));
            }
        }
        if accepted.contains(&scope) {
            return Err(format!("{label} contains duplicate prefix '{scope}'"));
        }
        if accepted
            .iter()
            .any(|existing| scopes_have_ambiguous_case(existing, scope))
        {
            return Err(format!("{label} contains case-ambiguous prefix '{scope}'"));
        }
        accepted.push(scope);
    }
    Ok(())
}

pub(super) fn validate_admission_ceilings(
    max_active_children: u32,
    max_child_executions: u32,
    max_execution_nodes: u32,
    max_causal_depth: u32,
    max_queued_assignments: Option<u32>,
) -> Result<(), String> {
    if !(1..=8).contains(&max_active_children) {
        return Err("max active child agents must be within 1..=8".to_owned());
    }
    if max_child_executions > 256 {
        return Err("max direct child executions must be within 0..=256".to_owned());
    }
    if !(1..=64).contains(&max_execution_nodes) {
        return Err("max mixed execution nodes must be within 1..=64".to_owned());
    }
    if !(1..=16).contains(&max_causal_depth) {
        return Err("max causal depth must be within 1..=16".to_owned());
    }
    if max_queued_assignments.is_some_and(|value| !(1..=8).contains(&value)) {
        return Err("max queued assignments must be within 1..=8".to_owned());
    }
    Ok(())
}

pub(super) fn validate_assignment_message(request: &NewAgentAssignment) -> Result<(), String> {
    let message = &request.message;
    for (name, value) in [
        (
            "message deduplication key",
            message.deduplication_key.as_str(),
        ),
        ("message id", message.message_id.as_str()),
        ("message channel id", message.channel_id.as_str()),
        ("message source agent id", message.source_agent_id.as_str()),
        (
            "message source session id",
            message.source_session_id.as_str(),
        ),
        (
            "message target session id",
            message.target_session_id.as_str(),
        ),
    ] {
        validate_runtime_identifier(value, name, 256)?;
    }
    if message.text != request.task {
        return Err("assignment message text must exactly match its admitted task".to_owned());
    }
    if request.requester_agent_id.as_deref() != Some(&message.source_agent_id) {
        return Err("assignment message source must be its requester".to_owned());
    }
    if message.channel_id != canonical_agent_channel_id(&message.source_agent_id, &request.agent_id)
    {
        return Err("assignment message channel does not match its participants".to_owned());
    }
    let kind_matches = matches!(
        (request.kind, message.kind),
        (
            AgentAssignmentKind::Instruction,
            AgentMessageKind::Instruction
        ) | (AgentAssignmentKind::Request, AgentMessageKind::Request)
            | (AgentAssignmentKind::Operator, AgentMessageKind::Instruction)
    );
    if !kind_matches || message.reply_to.is_some() {
        return Err("assignment message kind/reply linkage is incompatible".to_owned());
    }
    let authority_matches = match request.kind {
        AgentAssignmentKind::Instruction => message.authority == AgentMessageAuthority::Owner,
        AgentAssignmentKind::Request => matches!(
            message.authority,
            AgentMessageAuthority::Peer | AgentMessageAuthority::Owner
        ),
        AgentAssignmentKind::Operator => message.authority == AgentMessageAuthority::Operator,
        AgentAssignmentKind::DirectWorker => false,
    };
    if !authority_matches {
        return Err("assignment message authority is incompatible".to_owned());
    }
    if message.source_name.as_ref().is_some_and(|name| {
        name.is_empty()
            || name.as_bytes().len() > MAX_NAME_BYTES
            || name.chars().any(char::is_control)
    }) {
        return Err("assignment message source name is invalid".to_owned());
    }
    Ok(())
}

pub(super) fn encode_json(value: &Value) -> Result<String, String> {
    serde_json::to_string(value).map_err(|error| format!("encode agent coordination JSON: {error}"))
}

pub(super) fn assignment_message_payload(
    request: &NewAgentAssignment,
    assignment_id: &str,
    execution_id: &str,
) -> Result<Value, String> {
    Ok(json!({
        "messagePurpose":"assignment_admission",
        "messageId":request.message.message_id,
        "channelId":request.message.channel_id,
        "kind":serde_json::to_value(request.message.kind)
            .map_err(|error| format!("encode assignment message kind: {error}"))?,
        "authority":serde_json::to_value(request.message.authority)
            .map_err(|error| format!("encode assignment message authority: {error}"))?,
        "text":request.message.text,
        "sourceName":request.message.source_name,
        "sourceAgentId":request.message.source_agent_id,
        "sourceSessionId":request.message.source_session_id,
        "targetAgentId":request.agent_id,
        "targetSessionId":request.message.target_session_id,
        "assignmentId":assignment_id,
        "executionId":execution_id,
        "replyTo":request.message.reply_to,
        "traceId":request.trace_id,
        "causalDepth":request.causal_depth,
        "autonomousHop":request.message.autonomous_hop,
        "actionable":true,
        "expiresAt":request.deadline_at,
    }))
}

pub(super) fn agent_provision_payload(
    request: &NewAgentAdmission,
    spawner: &AgentInstanceRecord,
    agent_id: &str,
    session_id: &str,
    assignment_id: &str,
    execution_id: &str,
) -> Value {
    json!({
        "messagePurpose":"assignment_admission",
        "agentId":agent_id,
        "sessionId":session_id,
        "assignmentId":assignment_id,
        "executionId":execution_id,
        "rootSessionId":request.root_session_id,
        "workspaceId":request.workspace_id,
        "name":request.name,
        "task":request.task,
        "context":request.context,
        "model":request.model,
        "reasoningLevel":request.reasoning_level,
        "messageId":format!("agent_message_spawn_{assignment_id}"),
        "channelId":canonical_agent_channel_id(&spawner.agent_id,agent_id),
        "kind":"instruction",
        "authority":"owner",
        "text":request.task,
        "sourceAgentId":spawner.agent_id,
        "sourceSessionId":spawner.session_id,
        "sourceName":spawner.name,
        "targetAgentId":agent_id,
        "targetSessionId":session_id,
        "replyTo":Value::Null,
        "traceId":request.trace_id,
        "causalDepth":request.causal_depth,
        "autonomousHop":request.autonomous_hop,
        "actionable":true,
        "expiresAt":request.deadline_at,
    })
}

pub(super) fn canonical_agent_channel_id(first: &str, second: &str) -> String {
    if first <= second {
        format!("agent_channel:{first}:{second}")
    } else {
        format!("agent_channel:{second}:{first}")
    }
}

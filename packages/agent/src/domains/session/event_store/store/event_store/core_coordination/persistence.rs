//! Canonical SQLite row operations and immutable result custody.

use super::*;

pub(super) fn insert_agent_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    agent: &AgentRecord,
) -> Result<()> {
    transaction.execute(
        "INSERT INTO agents(
            agent_id,transcript_session_id,root_agent_id,workspace_id,parent_agent_id,
            management_owner_agent_id,name,visibility,lifecycle,default_model,
            default_reasoning_level,default_capability_grant_json,
            default_write_scopes_json,default_limits_json,created_at,updated_at,closed_at
         ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
        params![
            agent.agent_id,
            agent.transcript_session_id,
            agent.root_agent_id,
            agent.workspace_id,
            agent.parent_agent_id,
            agent.management_owner_agent_id,
            agent.name,
            agent.visibility.as_str(),
            agent.lifecycle.as_str(),
            agent.defaults.model,
            agent.defaults.reasoning_level,
            serde_json::to_string(&agent.defaults.capability_grant)?,
            serde_json::to_string(&agent.defaults.write_scopes)?,
            serde_json::to_string(&agent.defaults.limits)?,
            agent.created_at,
            agent.updated_at,
            agent.closed_at,
        ],
    )?;
    Ok(())
}

pub(super) fn admit_assignment_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    request: &NewAssignment,
) -> Result<AssignmentRecord> {
    validate_new_assignment(request)?;
    if let Some(existing) = query_assignment_by_admission_key(transaction, &request.admission_key)?
    {
        validate_assignment_replay(&existing, request)?;
        return Ok(existing);
    }
    let agent = require_open_agent(transaction, &request.agent_id)?;
    if let Some(requester_id) = request.requested_by_agent_id.as_deref() {
        let _ = require_open_agent(transaction, requester_id)?;
    }
    if request.kind == AssignmentKind::Request && request.requested_by_agent_id.is_none() {
        return Err(EventStoreError::InvalidOperation(
            "peer request assignment requires a requester agent".to_owned(),
        ));
    }
    let queued = transaction.query_row(
        "SELECT COUNT(*) FROM agent_assignments
         WHERE agent_id=?1 AND status IN ('offered','queued')",
        [&agent.agent_id],
        |row| row.get::<_, u16>(0),
    )?;
    if queued >= agent.defaults.limits.max_queued_assignments {
        return Err(EventStoreError::InvalidOperation(format!(
            "agent assignment queue is full ({})",
            agent.defaults.limits.max_queued_assignments
        )));
    }
    let parent = validate_parent_assignment(
        transaction,
        request.parent_assignment_id.as_deref(),
        request.requested_by_agent_id.as_deref(),
    )?;
    let (trace_id, causal_depth, causal_ordinal) = if let Some(parent) = parent.as_ref() {
        if request
            .trace_id
            .as_deref()
            .is_some_and(|trace_id| trace_id != parent.trace_id)
        {
            return Err(EventStoreError::InvalidOperation(
                "child assignment trace must match its causal parent".to_owned(),
            ));
        }
        let depth = parent.causal_depth.checked_add(1).ok_or_else(|| {
            EventStoreError::InvalidOperation("assignment causal depth overflow".to_owned())
        })?;
        if depth > 16 {
            return Err(EventStoreError::InvalidOperation(
                "assignment causal depth exceeds 16".to_owned(),
            ));
        }
        let ordinal = transaction.query_row(
            "SELECT COALESCE(MAX(causal_ordinal),-1)+1 FROM agent_assignments
             WHERE parent_assignment_id=?1",
            [&parent.assignment_id],
            |row| row.get::<_, u64>(0),
        )?;
        (parent.trace_id.clone(), depth, Some(ordinal))
    } else {
        (
            request
                .trace_id
                .clone()
                .unwrap_or_else(|| stable_id("agent_trace", &[&request.admission_key])),
            0,
            None,
        )
    };
    validate_identifier("assignment trace id", &trace_id)?;
    let trace_owner = if let Some(parent) = parent.as_ref() {
        let parent_agent = query_agent(transaction, &parent.agent_id)?.ok_or_else(|| {
            EventStoreError::Internal("parent assignment agent disappeared".to_owned())
        })?;
        query_agent(transaction, &parent_agent.root_agent_id)?.ok_or_else(|| {
            EventStoreError::Internal("parent assignment root agent disappeared".to_owned())
        })?
    } else if let Some(requester_id) = request.requested_by_agent_id.as_deref() {
        let requester = query_agent(transaction, requester_id)?.ok_or_else(|| {
            EventStoreError::Internal("assignment requester disappeared".to_owned())
        })?;
        query_agent(transaction, &requester.root_agent_id)?.ok_or_else(|| {
            EventStoreError::Internal("assignment requester root agent disappeared".to_owned())
        })?
    } else {
        query_agent(transaction, &agent.root_agent_id)?.ok_or_else(|| {
            EventStoreError::Internal("assignment root agent disappeared".to_owned())
        })?
    };
    ensure_coordination_trace_in_tx(
        transaction,
        &trace_id,
        &trace_owner.agent_id,
        &trace_owner.transcript_session_id,
    )?;
    if let Some(retry_id) = request.retry_of_assignment_id.as_deref() {
        let retry = query_assignment(transaction, retry_id)?.ok_or_else(|| {
            EventStoreError::InvalidOperation(format!(
                "retry assignment '{retry_id}' was not found"
            ))
        })?;
        if !retry.status.is_terminal() || retry.agent_id != agent.agent_id {
            return Err(EventStoreError::InvalidOperation(
                "retryOf must reference terminal work for the same agent".to_owned(),
            ));
        }
    }
    let queue_ordinal = transaction.query_row(
        "SELECT COALESCE(MAX(queue_ordinal),-1)+1 FROM agent_assignments WHERE agent_id=?1",
        [&agent.agent_id],
        |row| row.get::<_, u64>(0),
    )?;
    let limits = request
        .limits
        .clone()
        .unwrap_or_else(|| agent.defaults.limits.clone());
    validate_limits(&limits)?;
    let write_scopes = request
        .write_scopes
        .clone()
        .unwrap_or_else(|| agent.defaults.write_scopes.clone());
    validate_write_scopes(&write_scopes)?;
    let capability_grant = request
        .capability_grant
        .clone()
        .unwrap_or_else(|| agent.defaults.capability_grant.clone());
    validate_json_size(
        "assignment capability snapshot",
        &capability_grant,
        MAX_CONTEXT_BYTES,
    )?;
    let assignment_id = stable_id("agent_assignment", &[&request.admission_key]);
    let now = chrono::Utc::now().to_rfc3339();
    let status = request.kind.initial_status();
    transaction.execute(
        "INSERT INTO agent_assignments(
            assignment_id,admission_key,agent_id,requested_by_agent_id,parent_assignment_id,
            retry_of_assignment_id,kind,status,queue_ordinal,trace_id,autonomous_hop,causal_depth,
            causal_ordinal,task,context_json,model,reasoning_level,capability_snapshot_json,
            write_scopes_snapshot_json,limits_snapshot_json,
            deadline_at,created_at,accepted_at,updated_at
         ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,
                   ?17,?18,?19,?20,?21,?22,?23,?22)",
        params![
            assignment_id,
            request.admission_key,
            agent.agent_id,
            request.requested_by_agent_id,
            request.parent_assignment_id,
            request.retry_of_assignment_id,
            request.kind.as_str(),
            status.as_str(),
            queue_ordinal,
            trace_id,
            request.autonomous_hop,
            causal_depth,
            causal_ordinal,
            request.task,
            serde_json::to_string(&request.context)?,
            request.model.as_ref().or(agent.defaults.model.as_ref()),
            request
                .reasoning_level
                .as_ref()
                .or(agent.defaults.reasoning_level.as_ref()),
            serde_json::to_string(&capability_grant)?,
            serde_json::to_string(&write_scopes)?,
            serde_json::to_string(&limits)?,
            request.deadline_at,
            now,
            (status == AssignmentStatus::Queued).then_some(now.clone()),
        ],
    )?;
    query_assignment(transaction, &assignment_id)?
        .ok_or_else(|| EventStoreError::Internal("admitted assignment disappeared".to_owned()))
}

pub(super) fn validate_parent_assignment(
    connection: &rusqlite::Connection,
    parent_assignment_id: Option<&str>,
    expected_agent_id: Option<&str>,
) -> Result<Option<AssignmentRecord>> {
    let Some(parent_assignment_id) = parent_assignment_id else {
        return Ok(None);
    };
    let parent = query_assignment(connection, parent_assignment_id)?.ok_or_else(|| {
        EventStoreError::InvalidOperation(format!(
            "parent assignment '{parent_assignment_id}' was not found"
        ))
    })?;
    if expected_agent_id.is_some_and(|agent_id| parent.agent_id != agent_id) {
        return Err(EventStoreError::InvalidOperation(
            "parent assignment does not belong to the requesting agent".to_owned(),
        ));
    }
    Ok(Some(parent))
}
pub(super) fn store_result_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    assignment_id: &str,
    terminal_status: AssignmentStatus,
    payload: Option<&Value>,
    error: Option<&str>,
    now: &str,
) -> Result<StoredResult> {
    let result_id = stable_id("agent_result", &[assignment_id]);
    let (inline_json, payload_blob_id, payload_sha256, payload_byte_count) =
        if let Some(payload) = payload {
            let bytes = serde_json::to_vec(payload)?;
            let digest = hex_sha256(&bytes);
            let byte_count = u64::try_from(bytes.len()).map_err(|_| {
                EventStoreError::InvalidOperation("assignment result is too large".to_owned())
            })?;
            if bytes.len() <= INLINE_RESULT_BYTES {
                (
                    Some(String::from_utf8(bytes).map_err(|utf8| {
                        EventStoreError::Internal(format!("serialized JSON was not UTF-8: {utf8}"))
                    })?),
                    None,
                    Some(digest),
                    byte_count,
                )
            } else {
                let blob_id = BlobRepo::store(transaction, &bytes, "application/json")?;
                (None, Some(blob_id), Some(digest), byte_count)
            }
        } else {
            (None, None, None, 0)
        };
    transaction.execute(
        "INSERT INTO agent_results(
            result_id,assignment_id,terminal_status,inline_json,payload_blob_id,
            payload_sha256,payload_byte_count,error,created_at
         ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        params![
            result_id,
            assignment_id,
            terminal_status.as_str(),
            inline_json,
            payload_blob_id,
            payload_sha256,
            payload_byte_count,
            error,
            now,
        ],
    )?;
    query_result(transaction, &result_id)?
        .ok_or_else(|| EventStoreError::Internal("assignment result disappeared".to_owned()))
}

pub(super) fn reconcile_and_schedule_result_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    assignment: &AssignmentRecord,
    status: AssignmentStatus,
    result_id: &str,
    error: Option<&str>,
    now: &str,
) -> Result<()> {
    let resolutions = reconcile_core_assignment_terminal_in_tx(
        transaction,
        &assignment.assignment_id,
        status.as_str(),
        serde_json::json!({
            "assignmentId":assignment.assignment_id,
            "resultId":result_id,
            "error":error,
        }),
        now,
    )?;
    for resolution in resolutions {
        let owner = require_open_agent(transaction, &resolution.wait.owner_agent_id)?;
        let autonomous_hop = resolution
            .wait
            .autonomous_hop
            .checked_add(1)
            .ok_or_else(|| {
                EventStoreError::InvalidOperation("coordination autonomous hop overflow".to_owned())
            })?;
        if !pause_coordination_trace_for_hop_in_tx(
            transaction,
            &resolution.wait.trace_id,
            autonomous_hop,
            &owner.agent_id,
            resolution.wait.owner_assignment_id.as_deref(),
        )? {
            let _ = insert_wake_in_tx(
                transaction,
                &owner.agent_id,
                &owner.transcript_session_id,
                resolution.wait.owner_assignment_id.as_deref(),
                "wait_result",
                &resolution.wait.wait_id,
                &resolution.wait.trace_id,
                autonomous_hop,
                30,
                None,
            )?;
        }
    }
    let Some(requester_id) = assignment.requested_by_agent_id.as_deref() else {
        return Ok(());
    };
    let requester = require_open_agent(transaction, requester_id)?;
    let absorbed = transaction.query_row(
        "SELECT EXISTS(
            SELECT 1 FROM coordination_wait_members member
            JOIN coordination_waits wait USING(wait_id)
            WHERE member.target_kind='agent_assignment' AND member.target_id=?1
              AND member.disposition IN ('pending','satisfied')
              AND wait.disposition IN ('pending','satisfied')
              AND wait.owner_agent_id=?2 AND wait.session_id=?3
         )",
        params![
            assignment.assignment_id,
            requester.agent_id,
            requester.transcript_session_id
        ],
        |row| row.get::<_, bool>(0),
    )?;
    if !absorbed {
        let target_assignment_id =
            assignment
                .parent_assignment_id
                .as_deref()
                .and_then(|parent_id| {
                    query_assignment(transaction, parent_id)
                        .ok()
                        .flatten()
                        .filter(|parent| parent.agent_id == requester.agent_id)
                        .map(|parent| parent.assignment_id)
                });
        let target_is_terminal = target_assignment_id
            .as_deref()
            .and_then(|assignment_id| query_assignment(transaction, assignment_id).ok().flatten())
            .is_some_and(|assignment| assignment.status.is_terminal());
        if !target_is_terminal {
            let message_hop = transaction.query_row(
                "SELECT COALESCE(MAX(autonomous_hop),0) FROM agent_message_metadata
                 WHERE assignment_id=?1",
                [&assignment.assignment_id],
                |row| row.get::<_, u32>(0),
            )?;
            let autonomous_hop = assignment
                .autonomous_hop
                .max(message_hop)
                .checked_add(1)
                .ok_or_else(|| {
                    EventStoreError::InvalidOperation(
                        "coordination autonomous hop overflow".to_owned(),
                    )
                })?;
            if !pause_coordination_trace_for_hop_in_tx(
                transaction,
                &assignment.trace_id,
                autonomous_hop,
                &requester.agent_id,
                target_assignment_id.as_deref(),
            )? {
                let _ = insert_wake_in_tx(
                    transaction,
                    &requester.agent_id,
                    &requester.transcript_session_id,
                    target_assignment_id.as_deref(),
                    "assignment_result",
                    &assignment.assignment_id,
                    &assignment.trace_id,
                    autonomous_hop,
                    35,
                    None,
                )?;
            }
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn insert_wake_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    target_agent_id: &str,
    target_session_id: &str,
    target_assignment_id: Option<&str>,
    cause_kind: &str,
    cause_id: &str,
    trace_id: &str,
    autonomous_hop: u32,
    priority: u8,
    not_before: Option<&str>,
) -> Result<WakeIntentRecord> {
    let idempotency_key = format!("{cause_kind}:{cause_id}:{target_agent_id}");
    let wake_id = stable_id("agent_wake", &[&idempotency_key]);
    let now = chrono::Utc::now().to_rfc3339();
    transaction.execute(
        "INSERT OR IGNORE INTO agent_wake_intents(
            wake_id,idempotency_key,target_agent_id,target_session_id,
            target_assignment_id,cause_kind,cause_id,trace_id,autonomous_hop,
            priority,not_before,created_at
         ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
        params![
            wake_id,
            idempotency_key,
            target_agent_id,
            target_session_id,
            target_assignment_id,
            cause_kind,
            cause_id,
            trace_id,
            autonomous_hop,
            priority,
            not_before,
            now,
        ],
    )?;
    let wake = query_wake(transaction, &wake_id)?
        .ok_or_else(|| EventStoreError::Internal("agent wake disappeared".to_owned()))?;
    if wake.target_agent_id != target_agent_id
        || wake.target_session_id != target_session_id
        || wake.target_assignment_id.as_deref() != target_assignment_id
        || wake.cause_kind != cause_kind
        || wake.cause_id != cause_id
        || wake.trace_id != trace_id
        || wake.autonomous_hop != autonomous_hop
        || wake.priority != priority
        || wake.not_before.as_deref() != not_before
    {
        return Err(EventStoreError::InvalidOperation(
            "agent wake idempotency conflict".to_owned(),
        ));
    }
    Ok(wake)
}

pub(super) fn query_agent(
    connection: &rusqlite::Connection,
    agent_id: &str,
) -> Result<Option<AgentRecord>> {
    connection
        .query_row(
            &format!("SELECT {AGENT_COLUMNS} FROM agents WHERE agent_id=?1"),
            [agent_id],
            map_agent,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn query_agent_by_session(
    connection: &rusqlite::Connection,
    session_id: &str,
) -> Result<Option<AgentRecord>> {
    connection
        .query_row(
            &format!("SELECT {AGENT_COLUMNS} FROM agents WHERE transcript_session_id=?1"),
            [session_id],
            map_agent,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn require_open_agent(
    connection: &rusqlite::Connection,
    agent_id: &str,
) -> Result<AgentRecord> {
    let agent = query_agent(connection, agent_id)?.ok_or_else(|| {
        EventStoreError::InvalidOperation(format!("agent '{agent_id}' was not found"))
    })?;
    if agent.lifecycle != AgentLifecycle::Open {
        return Err(EventStoreError::InvalidOperation(format!(
            "agent '{agent_id}' is {}",
            agent.lifecycle.as_str()
        )));
    }
    Ok(agent)
}

pub(super) fn query_assignment(
    connection: &rusqlite::Connection,
    assignment_id: &str,
) -> Result<Option<AssignmentRecord>> {
    connection
        .query_row(
            &format!("SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments WHERE assignment_id=?1"),
            [assignment_id],
            map_assignment,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn query_assignment_by_admission_key(
    connection: &rusqlite::Connection,
    admission_key: &str,
) -> Result<Option<AssignmentRecord>> {
    connection
        .query_row(
            &format!("SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments WHERE admission_key=?1"),
            [admission_key],
            map_assignment,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn query_next_queued_assignment(
    connection: &rusqlite::Connection,
    agent_id: &str,
) -> Result<Option<AssignmentRecord>> {
    connection
        .query_row(
            &format!(
                "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                 WHERE agent_id=?1 AND status='queued'
                 ORDER BY queue_ordinal,created_at,assignment_id LIMIT 1"
            ),
            [agent_id],
            map_assignment,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn query_attempt(
    connection: &rusqlite::Connection,
    attempt_id: &str,
) -> Result<Option<AssignmentAttemptRecord>> {
    connection
        .query_row(
            &format!("SELECT {ATTEMPT_COLUMNS} FROM agent_assignment_attempts WHERE attempt_id=?1"),
            [attempt_id],
            map_attempt,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn query_result(
    connection: &rusqlite::Connection,
    result_id: &str,
) -> Result<Option<StoredResult>> {
    connection
        .query_row(
            "SELECT result_id,assignment_id,terminal_status,inline_json,payload_blob_id,
                    payload_sha256,payload_byte_count,error,created_at
             FROM agent_results WHERE result_id=?1",
            [result_id],
            map_stored_result,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn query_result_by_assignment(
    connection: &rusqlite::Connection,
    assignment_id: &str,
) -> Result<Option<StoredResult>> {
    connection
        .query_row(
            "SELECT result_id,assignment_id,terminal_status,inline_json,payload_blob_id,
                    payload_sha256,payload_byte_count,error,created_at
             FROM agent_results WHERE assignment_id=?1",
            [assignment_id],
            map_stored_result,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn query_wake(
    connection: &rusqlite::Connection,
    wake_id: &str,
) -> Result<Option<WakeIntentRecord>> {
    connection
        .query_row(
            &format!("SELECT {WAKE_COLUMNS} FROM agent_wake_intents WHERE wake_id=?1"),
            [wake_id],
            map_wake,
        )
        .optional()
        .map_err(EventStoreError::from)
}

pub(super) fn map_agent(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentRecord> {
    let visibility = parse_enum_column(row, 7, "agent visibility", AgentVisibility::parse)?;
    let lifecycle = parse_enum_column(row, 8, "agent lifecycle", AgentLifecycle::parse)?;
    Ok(AgentRecord {
        agent_id: row.get(0)?,
        transcript_session_id: row.get(1)?,
        root_agent_id: row.get(2)?,
        workspace_id: row.get(3)?,
        parent_agent_id: row.get(4)?,
        management_owner_agent_id: row.get(5)?,
        name: row.get(6)?,
        visibility,
        lifecycle,
        defaults: AgentDefaults {
            model: row.get(9)?,
            reasoning_level: row.get(10)?,
            capability_grant: parse_json_column(row, 11)?,
            write_scopes: parse_json_column(row, 12)?,
            limits: parse_json_column(row, 13)?,
        },
        created_at: row.get(14)?,
        updated_at: row.get(15)?,
        closed_at: row.get(16)?,
    })
}

pub(super) fn map_assignment(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssignmentRecord> {
    Ok(AssignmentRecord {
        assignment_id: row.get(0)?,
        admission_key: row.get(1)?,
        agent_id: row.get(2)?,
        requested_by_agent_id: row.get(3)?,
        parent_assignment_id: row.get(4)?,
        retry_of_assignment_id: row.get(5)?,
        kind: parse_enum_column(row, 6, "assignment kind", AssignmentKind::parse)?,
        status: parse_enum_column(row, 7, "assignment status", AssignmentStatus::parse)?,
        queue_ordinal: row.get(8)?,
        trace_id: row.get(9)?,
        autonomous_hop: row.get(10)?,
        causal_depth: row.get(11)?,
        causal_ordinal: row.get(12)?,
        task: row.get(13)?,
        context: parse_json_column(row, 14)?,
        model: row.get(15)?,
        reasoning_level: row.get(16)?,
        capability_snapshot: parse_json_column(row, 17)?,
        write_scopes_snapshot: parse_json_column(row, 18)?,
        limits_snapshot: parse_json_column(row, 19)?,
        deadline_at: row.get(20)?,
        created_at: row.get(21)?,
        accepted_at: row.get(22)?,
        started_at: row.get(23)?,
        completed_at: row.get(24)?,
        updated_at: row.get(25)?,
    })
}

pub(super) fn map_attempt(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssignmentAttemptRecord> {
    Ok(AssignmentAttemptRecord {
        attempt_id: row.get(0)?,
        assignment_id: row.get(1)?,
        attempt_number: row.get(2)?,
        status: row.get(3)?,
        run_id: row.get(4)?,
        baseline_event_sequence: row.get(5)?,
        started_at: row.get(6)?,
        completed_at: row.get(7)?,
        error: row.get(8)?,
    })
}

pub(super) fn map_stored_result(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredResult> {
    Ok(StoredResult {
        result_id: row.get(0)?,
        assignment_id: row.get(1)?,
        terminal_status: parse_enum_column(row, 2, "agent result status", AssignmentStatus::parse)?,
        inline_json: row.get(3)?,
        payload_blob_id: row.get(4)?,
        payload_sha256: row.get(5)?,
        payload_byte_count: row.get(6)?,
        error: row.get(7)?,
        created_at: row.get(8)?,
    })
}

pub(super) fn map_wake(row: &rusqlite::Row<'_>) -> rusqlite::Result<WakeIntentRecord> {
    Ok(WakeIntentRecord {
        wake_id: row.get(0)?,
        idempotency_key: row.get(1)?,
        target_agent_id: row.get(2)?,
        target_session_id: row.get(3)?,
        target_assignment_id: row.get(4)?,
        cause_kind: row.get(5)?,
        cause_id: row.get(6)?,
        trace_id: row.get(7)?,
        autonomous_hop: row.get(8)?,
        materialized_message_id: row.get(9)?,
        priority: row.get(10)?,
        disposition: row.get(11)?,
        not_before: row.get(12)?,
        lease_id: row.get(13)?,
        delivered_by_lease_id: row.get(14)?,
        lease_count: row.get(15)?,
        last_error: row.get(16)?,
        created_at: row.get(17)?,
        leased_at: row.get(18)?,
        delivered_at: row.get(19)?,
        cancelled_at: row.get(20)?,
    })
}

pub(super) fn load_result(
    connection: &rusqlite::Connection,
    stored: StoredResult,
) -> Result<AgentResultRecord> {
    let bytes = match (&stored.inline_json, &stored.payload_blob_id) {
        (Some(inline), None) => Some(inline.as_bytes().to_vec()),
        (None, Some(blob_id)) => Some(
            BlobRepo::get_content(connection, blob_id)?
                .ok_or_else(|| EventStoreError::BlobNotFound(blob_id.clone()))?,
        ),
        (None, None) => None,
        (Some(_), Some(_)) => {
            return Err(EventStoreError::Internal(
                "agent result has both inline and blob payloads".to_owned(),
            ));
        }
    };
    let payload = if let Some(bytes) = bytes {
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) != stored.payload_byte_count
            || stored.payload_sha256.as_deref() != Some(hex_sha256(&bytes).as_str())
        {
            return Err(EventStoreError::Internal(
                "agent result payload integrity mismatch".to_owned(),
            ));
        }
        Some(serde_json::from_slice(&bytes)?)
    } else {
        None
    };
    Ok(AgentResultRecord {
        result_id: stored.result_id,
        assignment_id: stored.assignment_id,
        terminal_status: stored.terminal_status,
        payload,
        payload_blob_id: stored.payload_blob_id,
        payload_sha256: stored.payload_sha256,
        payload_byte_count: stored.payload_byte_count,
        error: stored.error,
        created_at: stored.created_at,
    })
}

pub(super) fn parse_json_column<T: serde::de::DeserializeOwned>(
    row: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<T> {
    let value = row.get::<_, String>(index)?;
    serde_json::from_str(&value).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

pub(super) fn parse_enum_column<T>(
    row: &rusqlite::Row<'_>,
    index: usize,
    label: &'static str,
    parse: impl FnOnce(&str) -> Option<T>,
) -> rusqlite::Result<T> {
    let value = row.get::<_, String>(index)?;
    parse(&value).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unknown {label} '{value}'"),
            )),
        )
    })
}

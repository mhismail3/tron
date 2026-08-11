//! Canonical reusable-agent row decoding and exact lookups.
//!
//! Every operational submodule shares these mappings instead of duplicating SQL interpretation.

use super::*;

pub(super) fn invalid_sql_value(index: usize, kind: &str, value: &str) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        index,
        rusqlite::types::Type::Text,
        Box::new(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unknown {kind} '{value}'"),
        )),
    )
}

pub(super) fn decode_json(index: usize, value: String) -> rusqlite::Result<Value> {
    serde_json::from_str(&value).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

pub(super) fn decode_optional_json(
    index: usize,
    value: Option<String>,
) -> rusqlite::Result<Option<Value>> {
    value.map(|value| decode_json(index, value)).transpose()
}

pub(super) fn map_agent(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentInstanceRecord> {
    let kind = row.get::<_, String>(6)?;
    let visibility = row.get::<_, String>(10)?;
    let state = row.get::<_, String>(11)?;
    Ok(AgentInstanceRecord {
        agent_id: row.get(0)?,
        session_id: row.get(1)?,
        root_session_id: row.get(2)?,
        workspace_id: row.get(3)?,
        spawned_by_agent_id: row.get(4)?,
        management_owner_agent_id: row.get(5)?,
        kind: AgentInstanceKind::parse(&kind)
            .ok_or_else(|| invalid_sql_value(6, "agent kind", &kind))?,
        role_id: row.get(7)?,
        role_version: row.get(8)?,
        name: row.get(9)?,
        visibility: AgentVisibility::parse(&visibility)
            .ok_or_else(|| invalid_sql_value(10, "agent visibility", &visibility))?,
        state: AgentInstanceState::parse(&state)
            .ok_or_else(|| invalid_sql_value(11, "agent state", &state))?,
        default_model: row.get(12)?,
        default_reasoning_level: row.get(13)?,
        tool_grant: decode_json(14, row.get(14)?)?,
        write_scopes: decode_json(15, row.get(15)?)?,
        limits: decode_json(16, row.get(16)?)?,
        created_at: row.get(17)?,
        updated_at: row.get(18)?,
        closed_at: row.get(19)?,
    })
}

pub(super) fn map_assignment(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentAssignmentRecord> {
    let kind = row.get::<_, String>(5)?;
    let status = row.get::<_, String>(6)?;
    Ok(AgentAssignmentRecord {
        assignment_id: row.get(0)?,
        execution_id: row.get(1)?,
        agent_id: row.get(2)?,
        requester_agent_id: row.get(3)?,
        delegator_agent_id: row.get(4)?,
        kind: AgentAssignmentKind::parse(&kind)
            .ok_or_else(|| invalid_sql_value(5, "agent assignment kind", &kind))?,
        status: AgentAssignmentStatus::parse(&status)
            .ok_or_else(|| invalid_sql_value(6, "agent assignment status", &status))?,
        admission_key: row.get(7)?,
        queue_ordinal: row.get(8)?,
        task: row.get(9)?,
        context: decode_json(10, row.get(10)?)?,
        model: row.get(11)?,
        reasoning_level: row.get(12)?,
        authority_snapshot: decode_json(13, row.get(13)?)?,
        resource_snapshot: decode_json(14, row.get(14)?)?,
        write_scopes_snapshot: decode_json(15, row.get(15)?)?,
        limits_snapshot: decode_json(16, row.get(16)?)?,
        retry_of_assignment_id: row.get(17)?,
        result_id: row.get(18)?,
        result_reference: decode_optional_json(19, row.get(19)?)?,
        error: row.get(20)?,
        deadline_at: row.get(21)?,
        created_at: row.get(22)?,
        accepted_at: row.get(23)?,
        started_at: row.get(24)?,
        completed_at: row.get(25)?,
        updated_at: row.get(26)?,
    })
}

pub(super) fn map_execution(row: &rusqlite::Row<'_>) -> rusqlite::Result<ExecutionNodeRecord> {
    let kind = row.get::<_, String>(1)?;
    Ok(ExecutionNodeRecord {
        execution_id: row.get(0)?,
        kind: ExecutionKind::parse(&kind)
            .ok_or_else(|| invalid_sql_value(1, "execution kind", &kind))?,
        parent_execution_id: row.get(2)?,
        owner_agent_id: row.get(3)?,
        root_session_id: row.get(4)?,
        trace_id: row.get(5)?,
        causal_depth: row.get(6)?,
        child_slot: row.get(7)?,
        worker_invocation_id: row.get(8)?,
        assignment_id: row.get(9)?,
        created_at: row.get(10)?,
    })
}

pub(super) fn map_coordination_trace_state(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<CoordinationTraceStateRecord> {
    let state = row.get::<_, String>(2)?;
    if !matches!(state.as_str(), "active" | "paused") {
        return Err(invalid_sql_value(2, "coordination trace state", &state));
    }
    Ok(CoordinationTraceStateRecord {
        trace_id: row.get(0)?,
        root_session_id: row.get(1)?,
        paused: state == "paused",
        reason: row.get(3)?,
        created_at: row.get(4)?,
        updated_at: row.get(5)?,
        paused_at: row.get(6)?,
        resumed_at: row.get(7)?,
    })
}

pub(super) fn map_attempt(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AgentAssignmentAttemptRecord> {
    Ok(AgentAssignmentAttemptRecord {
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

pub(super) fn map_execution_event(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AgentExecutionEventRecord> {
    Ok(AgentExecutionEventRecord {
        event_id: row.get(0)?,
        execution_id: row.get(1)?,
        sequence: row.get(2)?,
        kind: row.get(3)?,
        details: decode_json(4, row.get(4)?)?,
        occurred_at: row.get(5)?,
    })
}

pub(super) fn map_outbox(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentOutboxRecord> {
    let kind = row.get::<_, String>(2)?;
    let disposition = row.get::<_, String>(7)?;
    Ok(AgentOutboxRecord {
        outbox_id: row.get(0)?,
        deduplication_key: row.get(1)?,
        kind: AgentOutboxKind::parse(&kind)
            .ok_or_else(|| invalid_sql_value(2, "agent outbox kind", &kind))?,
        agent_id: row.get(3)?,
        assignment_id: row.get(4)?,
        execution_id: row.get(5)?,
        payload: decode_json(6, row.get(6)?)?,
        disposition: AgentOutboxDisposition::parse(&disposition)
            .ok_or_else(|| invalid_sql_value(7, "agent outbox disposition", &disposition))?,
        attempts: row.get(8)?,
        last_error: row.get(9)?,
        next_attempt_at: row.get(10)?,
        created_at: row.get(11)?,
        processed_at: row.get(12)?,
    })
}

pub(super) fn map_grant(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentManagementGrantRecord> {
    let capability = row.get::<_, String>(5)?;
    Ok(AgentManagementGrantRecord {
        grant_id: row.get(0)?,
        idempotency_key: row.get(1)?,
        target_agent_id: row.get(2)?,
        grantee_agent_id: row.get(3)?,
        granted_by_agent_id: row.get(4)?,
        capability: AgentManagementCapability::parse(&capability)
            .ok_or_else(|| invalid_sql_value(5, "management capability", &capability))?,
        created_at: row.get(6)?,
        revoked_at: row.get(7)?,
    })
}

pub(super) fn map_claim(row: &rusqlite::Row<'_>) -> rusqlite::Result<WorkspaceClaimRecord> {
    let kind = row.get::<_, String>(6)?;
    let state = row.get::<_, String>(8)?;
    let raw_process_id = row.get::<_, Option<i64>>(12)?;
    let process_id = raw_process_id.map(u32::try_from).transpose().map_err(|_| {
        invalid_sql_value(
            12,
            "workspace process id",
            &raw_process_id.unwrap().to_string(),
        )
    })?;
    Ok(WorkspaceClaimRecord {
        claim_id: row.get(0)?,
        idempotency_key: row.get(1)?,
        execution_id: row.get(2)?,
        agent_id: row.get(3)?,
        holder_session_id: row.get(4)?,
        workspace_id: row.get(5)?,
        kind: WorkspaceClaimKind::parse(&kind)
            .ok_or_else(|| invalid_sql_value(6, "workspace claim kind", &kind))?,
        canonical_scope: row.get(7)?,
        state: WorkspaceClaimState::parse(&state)
            .ok_or_else(|| invalid_sql_value(8, "workspace claim state", &state))?,
        requested_at: row.get(9)?,
        acquired_at: row.get(10)?,
        released_at: row.get(11)?,
        process_id,
        process_identity: row.get(13)?,
    })
}

pub(super) fn query_agent(
    connection: &rusqlite::Connection,
    agent_id: &str,
) -> Result<Option<AgentInstanceRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {AGENT_COLUMNS} FROM agent_instances WHERE agent_id=?1"),
            [agent_id],
            map_agent,
        )
        .optional()
        .map_err(|error| format!("load agent identity: {error}"))
}

pub(super) fn query_agent_by_session(
    connection: &rusqlite::Connection,
    session_id: &str,
) -> Result<Option<AgentInstanceRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {AGENT_COLUMNS} FROM agent_instances WHERE session_id=?1"),
            [session_id],
            map_agent,
        )
        .optional()
        .map_err(|error| format!("load session agent identity: {error}"))
}

pub(super) fn require_agent(
    connection: &rusqlite::Connection,
    agent_id: &str,
    role: &str,
) -> Result<AgentInstanceRecord, String> {
    query_agent(connection, agent_id)?.ok_or_else(|| format!("{role} '{agent_id}' was not found"))
}

pub(super) fn agent_is_management_ancestor(
    connection: &rusqlite::Connection,
    actor_agent_id: &str,
    target_agent_id: &str,
) -> Result<bool, String> {
    connection
        .query_row(
            "WITH RECURSIVE ancestry(agent_id,owner_agent_id) AS (
                SELECT agent_id,management_owner_agent_id
                FROM agent_instances WHERE agent_id=?2
                UNION ALL
                SELECT parent.agent_id,parent.management_owner_agent_id
                FROM agent_instances parent
                JOIN ancestry child ON child.owner_agent_id=parent.agent_id
             )
             SELECT EXISTS(SELECT 1 FROM ancestry WHERE agent_id=?1)",
            params![actor_agent_id, target_agent_id],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("inspect agent management ownership: {error}"))
}

pub(super) fn require_quiescent_agent(
    transaction: &Transaction<'_>,
    agent_id: &str,
    action: &str,
) -> Result<AgentInstanceRecord, String> {
    let agent = require_agent(transaction, agent_id, action)?;
    if agent.state != AgentInstanceState::Idle {
        return Err(format!(
            "cannot {action} agent '{agent_id}' while {}",
            agent.state.as_str()
        ));
    }
    let busy = transaction
        .query_row(
            "SELECT EXISTS(
                SELECT 1 FROM agent_assignments
                WHERE agent_id=?1
                  AND status IN ('offered','accepted','queued','running','waiting')
                UNION ALL
                SELECT 1 FROM agent_write_claims
                WHERE agent_id=?1 AND state IN ('queued','held')
             )",
            [agent_id],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("inspect reusable agent quiescence: {error}"))?;
    if busy {
        return Err(format!(
            "cannot {action} agent '{agent_id}' while work is pending"
        ));
    }
    Ok(agent)
}

pub(super) fn owned_agent_subtree(
    connection: &rusqlite::Connection,
    agent_id: &str,
) -> Result<Vec<String>, String> {
    let mut statement = connection
        .prepare(
            "WITH RECURSIVE subtree(agent_id,depth) AS (
                SELECT agent_id,0 FROM agent_instances WHERE agent_id=?1
                UNION ALL
                SELECT child.agent_id,subtree.depth+1
                FROM agent_instances child
                JOIN subtree ON child.management_owner_agent_id=subtree.agent_id
             )
             SELECT agent_id FROM subtree ORDER BY depth,agent_id",
        )
        .map_err(|error| format!("prepare owned agent subtree: {error}"))?;
    statement
        .query_map([agent_id], |row| row.get::<_, String>(0))
        .map_err(|error| format!("query owned agent subtree: {error}"))?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|error| format!("decode owned agent subtree: {error}"))
}

pub(super) fn query_assignment(
    connection: &rusqlite::Connection,
    assignment_id: &str,
) -> Result<Option<AgentAssignmentRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments WHERE assignment_id=?1"),
            [assignment_id],
            map_assignment,
        )
        .optional()
        .map_err(|error| format!("load agent assignment: {error}"))
}

pub(super) fn query_assignment_by_admission_key(
    connection: &rusqlite::Connection,
    admission_key: &str,
) -> Result<Option<AgentAssignmentRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments WHERE admission_key=?1"),
            [admission_key],
            map_assignment,
        )
        .optional()
        .map_err(|error| format!("load idempotent agent admission: {error}"))
}

pub(super) fn agent_result_reference_in_tx(
    connection: &rusqlite::Connection,
    result_id: &str,
    assignment_id: &str,
    agent_id: &str,
) -> Result<Value, String> {
    let payload = crate::shared::storage::owned_payload_ref(
        connection,
        "agent_assignment",
        result_id,
        "result",
    )
    .map_err(|error| format!("load agent result ownership: {error:#}"))?
    .ok_or_else(|| format!("agent result '{result_id}' has no durable owner"))?;
    Ok(json!({
        "kind":"agent_assignment_result_reference",
        "resultId":result_id,
        "agentId":agent_id,
        "assignmentId":assignment_id,
        "contentSha256":format!("sha256:{}",payload.payload_hash),
        "sizeBytes":payload.payload_size_bytes,
        "preview":payload.payload_preview,
        "message":"The exact assignment result is stored durably. Read only the JSON pointer/page needed through result_read.",
    }))
}

pub(super) fn agent_result_record(
    connection: &rusqlite::Connection,
    result_id: &str,
) -> Result<Option<AgentResultRecord>, String> {
    let identity = connection
        .query_row(
            "SELECT agent_id,assignment_id FROM agent_assignments
             WHERE result_id=?1 AND status='completed'",
            [result_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|error| format!("load agent result identity: {error}"))?;
    identity
        .map(|(agent_id, assignment_id)| {
            Ok(AgentResultRecord {
                result_id: result_id.to_owned(),
                reference: agent_result_reference_in_tx(
                    connection,
                    result_id,
                    &assignment_id,
                    &agent_id,
                )?,
                agent_id,
                assignment_id,
            })
        })
        .transpose()
}

pub(super) fn resolve_agent_result_in_tx(
    connection: &rusqlite::Connection,
    result_id: &str,
) -> Result<Option<Value>, String> {
    let stored = connection
        .query_row(
            "SELECT result_json FROM agent_assignments WHERE result_id=?1",
            [result_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| format!("load durable agent result: {error}"))?;
    stored
        .map(|stored| {
            crate::shared::storage::resolve_owned_json_value(
                connection,
                "agent_assignment",
                result_id,
                "result",
                &stored,
            )
            .map_err(|error| format!("agent result storage integrity failure: {error:#}"))
        })
        .transpose()
}

pub(super) fn query_execution(
    connection: &rusqlite::Connection,
    execution_id: &str,
) -> Result<Option<ExecutionNodeRecord>, String> {
    connection
        .query_row(
            "SELECT node.execution_id,node.kind,node.parent_execution_id,node.owner_agent_id,
                    node.root_session_id,node.trace_id,node.causal_depth,node.child_slot,
                    node.worker_invocation_id,
                    COALESCE(node.assignment_id,direct.assignment_id),node.created_at
             FROM execution_nodes node
             LEFT JOIN direct_worker_agent_runs direct
               ON direct.worker_invocation_id=node.worker_invocation_id
             WHERE node.execution_id=?1",
            [execution_id],
            map_execution,
        )
        .optional()
        .map_err(|error| format!("load execution node: {error}"))
}

pub(super) fn query_coordination_trace_state(
    connection: &rusqlite::Connection,
    trace_id: &str,
) -> Result<Option<CoordinationTraceStateRecord>, String> {
    connection
        .query_row(
            &format!(
                "SELECT {COORDINATION_TRACE_STATE_COLUMNS}
                 FROM coordination_trace_states WHERE trace_id=?1"
            ),
            [trace_id],
            map_coordination_trace_state,
        )
        .optional()
        .map_err(|error| format!("load coordination trace state: {error}"))
}

pub(super) fn coordination_trace_paused_for_execution_in_tx(
    transaction: &Transaction<'_>,
    execution_id: &str,
) -> Result<bool, String> {
    transaction
        .query_row(
            "SELECT EXISTS(
                SELECT 1
                FROM execution_nodes node
                JOIN coordination_trace_states trace_state
                  ON trace_state.trace_id=node.trace_id AND trace_state.state='paused'
                WHERE node.execution_id=?1
             )",
            [execution_id],
            |row| row.get(0),
        )
        .map_err(|error| format!("inspect coordination trace pause: {error}"))
}

pub(super) fn query_attempt(
    connection: &rusqlite::Connection,
    attempt_id: &str,
) -> Result<Option<AgentAssignmentAttemptRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {ATTEMPT_COLUMNS} FROM agent_assignment_attempts WHERE attempt_id=?1"),
            [attempt_id],
            map_attempt,
        )
        .optional()
        .map_err(|error| format!("load agent assignment attempt: {error}"))
}

pub(super) fn query_running_attempt(
    connection: &rusqlite::Connection,
    assignment_id: &str,
) -> Result<Option<AgentAssignmentAttemptRecord>, String> {
    connection
        .query_row(
            &format!(
                "SELECT {ATTEMPT_COLUMNS} FROM agent_assignment_attempts
                 WHERE assignment_id=?1 AND status='running'"
            ),
            [assignment_id],
            map_attempt,
        )
        .optional()
        .map_err(|error| format!("load running agent assignment attempt: {error}"))
}

pub(super) fn query_outbox(
    connection: &rusqlite::Connection,
    outbox_id: &str,
) -> Result<Option<AgentOutboxRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {OUTBOX_COLUMNS} FROM agent_outbox WHERE outbox_id=?1"),
            [outbox_id],
            map_outbox,
        )
        .optional()
        .map_err(|error| format!("load agent outbox row: {error}"))
}

pub(super) fn query_outbox_by_key(
    connection: &rusqlite::Connection,
    key: &str,
) -> Result<Option<AgentOutboxRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {OUTBOX_COLUMNS} FROM agent_outbox WHERE deduplication_key=?1"),
            [key],
            map_outbox,
        )
        .optional()
        .map_err(|error| format!("load idempotent agent outbox row: {error}"))
}

pub(super) fn query_assignment_outbox(
    connection: &rusqlite::Connection,
    assignment_id: &str,
    kind: AgentOutboxKind,
) -> Result<Option<AgentOutboxRecord>, String> {
    connection
        .query_row(
            &format!(
                "SELECT {OUTBOX_COLUMNS} FROM agent_outbox
                 WHERE assignment_id=?1 AND kind=?2 ORDER BY created_at,outbox_id LIMIT 1"
            ),
            params![assignment_id, kind.as_str()],
            map_outbox,
        )
        .optional()
        .map_err(|error| format!("load assignment agent outbox row: {error}"))
}

pub(super) fn query_management_grant_by_key(
    connection: &rusqlite::Connection,
    key: &str,
) -> Result<Option<AgentManagementGrantRecord>, String> {
    connection
        .query_row(
            &format!(
                "SELECT {GRANT_COLUMNS} FROM agent_management_grants WHERE idempotency_key=?1"
            ),
            [key],
            map_grant,
        )
        .optional()
        .map_err(|error| format!("load agent management grant: {error}"))
}

pub(super) fn query_management_grant_by_id(
    connection: &rusqlite::Connection,
    grant_id: &str,
) -> Result<Option<AgentManagementGrantRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {GRANT_COLUMNS} FROM agent_management_grants WHERE grant_id=?1"),
            [grant_id],
            map_grant,
        )
        .optional()
        .map_err(|error| format!("load agent management grant result: {error}"))
}

pub(super) fn query_claim(
    connection: &rusqlite::Connection,
    claim_id: &str,
) -> Result<Option<WorkspaceClaimRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {CLAIM_COLUMNS} FROM agent_write_claims WHERE claim_id=?1"),
            [claim_id],
            map_claim,
        )
        .optional()
        .map_err(|error| format!("load workspace claim: {error}"))
}

pub(super) fn query_claim_by_key(
    connection: &rusqlite::Connection,
    key: &str,
) -> Result<Option<WorkspaceClaimRecord>, String> {
    connection
        .query_row(
            &format!("SELECT {CLAIM_COLUMNS} FROM agent_write_claims WHERE idempotency_key=?1"),
            [key],
            map_claim,
        )
        .optional()
        .map_err(|error| format!("load idempotent workspace claim: {error}"))
}

pub(super) fn append_execution_event_in_tx(
    transaction: &Transaction<'_>,
    execution_id: &str,
    kind: &str,
    details: &Value,
    occurred_at: &str,
) -> Result<AgentExecutionEventRecord, String> {
    let sequence = transaction
        .query_row(
            "SELECT COALESCE(MAX(sequence),-1)+1
             FROM agent_execution_events WHERE execution_id=?1",
            [execution_id],
            |row| row.get::<_, u64>(0),
        )
        .map_err(|error| format!("allocate agent execution event sequence: {error}"))?;
    let event_id = format!("agent_execution_event_{}", uuid::Uuid::now_v7());
    transaction
        .execute(
            "INSERT INTO agent_execution_events(
                event_id,execution_id,sequence,kind,details_json,occurred_at
             ) VALUES (?1,?2,?3,?4,?5,?6)",
            params![
                event_id,
                execution_id,
                sequence,
                kind,
                encode_json(details)?,
                occurred_at,
            ],
        )
        .map_err(|error| format!("append agent execution event: {error}"))?;
    Ok(AgentExecutionEventRecord {
        event_id,
        execution_id: execution_id.to_owned(),
        sequence,
        kind: kind.to_owned(),
        details: details.clone(),
        occurred_at: occurred_at.to_owned(),
    })
}

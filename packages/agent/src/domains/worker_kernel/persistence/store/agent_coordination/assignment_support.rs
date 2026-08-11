//! Assignment transition invariants and direct-worker coupling.
//!
//! Shared transition guards keep reusable and direct-worker agent assignments on one lifecycle.

use super::*;

pub(super) fn valid_assignment_transition(
    from: AgentAssignmentStatus,
    to: AgentAssignmentStatus,
) -> bool {
    use AgentAssignmentStatus as Status;
    matches!(
        (from, to),
        (
            Status::Offered,
            Status::Accepted | Status::Declined | Status::Cancelled | Status::Expired
        ) | (
            Status::Accepted,
            Status::Queued
                | Status::Running
                | Status::Cancelled
                | Status::TimedOut
                | Status::Expired
        ) | (
            Status::Queued,
            Status::Running | Status::Cancelled | Status::TimedOut | Status::Expired
        ) | (
            Status::Running,
            Status::Waiting
                | Status::Completed
                | Status::Failed
                | Status::Cancelled
                | Status::TimedOut
        ) | (
            Status::Waiting,
            Status::Running
                | Status::Completed
                | Status::Failed
                | Status::Cancelled
                | Status::TimedOut
        )
    )
}

pub(super) fn validate_assignment_transition_payload(
    request: &AgentAssignmentTransition,
) -> Result<(), String> {
    if request.target_status == AgentAssignmentStatus::Completed {
        if request.result.is_none() {
            return Err("completed agent assignments require an exact result".to_owned());
        }
        if request.error.is_some() {
            return Err("completed agent assignments cannot store a failure error".to_owned());
        }
    } else if request.result.is_some() {
        return Err("only completed agent assignments may store a result".to_owned());
    }
    if !request.target_status.is_terminal() && request.error.is_some() {
        return Err("nonterminal agent assignment transitions cannot store an error".to_owned());
    }
    Ok(())
}

pub(super) fn normalized_assignment_error(error: Option<&str>) -> Option<String> {
    error.map(|value| value.chars().take(MAX_ERROR_BYTES).collect::<String>())
}

pub(super) fn enforce_execution_node_ceiling(
    transaction: &Transaction<'_>,
    trace_id: &str,
    ceiling: u32,
) -> Result<(), String> {
    if !(1..=64).contains(&ceiling) {
        return Err("mixed execution node ceiling must be within 1..=64".to_owned());
    }
    let nodes = transaction
        .query_row(
            "SELECT COUNT(*) FROM execution_nodes WHERE trace_id=?1",
            [trace_id],
            |row| row.get::<_, u32>(0),
        )
        .map_err(|error| format!("count mixed coordination graph: {error}"))?;
    if nodes >= ceiling {
        return Err(format!(
            "coordination graph reached the configured ceiling of {ceiling} execution nodes"
        ));
    }
    Ok(())
}

pub(super) fn enforce_direct_child_execution_ceiling(
    transaction: &Transaction<'_>,
    trace_id: &str,
    parent_execution_id: Option<&str>,
    ceiling: u32,
) -> Result<(), String> {
    if ceiling > 256 {
        return Err("direct child execution ceiling must be within 0..=256".to_owned());
    }
    let children = transaction
        .query_row(
            "SELECT COUNT(*) FROM execution_nodes
             WHERE trace_id=?1 AND parent_execution_id IS ?2",
            params![trace_id, parent_execution_id],
            |row| row.get::<_, u32>(0),
        )
        .map_err(|error| format!("count direct child executions: {error}"))?;
    if children >= ceiling {
        let parent = parent_execution_id.unwrap_or("coordination root");
        return Err(format!(
            "direct child execution ceiling ({ceiling}) reached for '{parent}'"
        ));
    }
    Ok(())
}

pub(super) fn enforce_active_agent_ceiling(
    transaction: &Transaction<'_>,
    root_session_id: &str,
    exclude_agent_id: Option<&str>,
    ceiling: u32,
) -> Result<(), String> {
    let active = transaction
        .query_row(
            "SELECT COUNT(*) FROM agent_instances
             WHERE root_session_id=?1 AND visibility='nested'
               AND state IN ('provisioning','active','waiting')
               AND (?2 IS NULL OR agent_id!=?2)",
            params![root_session_id, exclude_agent_id],
            |row| row.get::<_, u32>(0),
        )
        .map_err(|error| format!("count active child agents: {error}"))?;
    if active >= ceiling {
        return Err(format!(
            "visible root reached the configured ceiling of {ceiling} active child agents"
        ));
    }
    Ok(())
}

pub(super) fn execution_has_live_children(
    transaction: &Transaction<'_>,
    execution_id: &str,
) -> Result<bool, String> {
    transaction
        .query_row(
            "SELECT EXISTS(
                SELECT 1 FROM execution_nodes child
                LEFT JOIN agent_assignments assignment
                  ON assignment.assignment_id=child.assignment_id
                LEFT JOIN worker_invocations invocation
                  ON invocation.invocation_id=child.worker_invocation_id
                WHERE child.parent_execution_id=?1
                  AND (
                    assignment.status IN ('offered','accepted','queued','running','waiting')
                    OR invocation.status IN ('queued','running')
                  )
             )",
            [execution_id],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| format!("inspect structured agent children: {error}"))
}

pub(super) fn update_agent_state_for_assignment(
    transaction: &Transaction<'_>,
    agent_id: &str,
    status: AgentAssignmentStatus,
    now: &str,
) -> Result<(), String> {
    let kind = transaction
        .query_row(
            "SELECT kind FROM agent_instances WHERE agent_id=?1",
            [agent_id],
            |row| row.get::<_, String>(0),
        )
        .map_err(|error| format!("load assignment agent kind: {error}"))?;
    if kind == AgentInstanceKind::DirectWorker.as_str() && status.is_terminal() {
        transaction
            .execute(
                "UPDATE agent_instances
                 SET state='closed',updated_at=?2,closed_at=COALESCE(closed_at,?2)
                 WHERE agent_id=?1",
                params![agent_id, now],
            )
            .map_err(|error| format!("close terminal direct worker agent: {error}"))?;
        return Ok(());
    }
    let state = match status {
        AgentAssignmentStatus::Waiting => AgentInstanceState::Waiting,
        status if status.is_terminal() => {
            let active = transaction
                .query_row(
                    "SELECT status FROM agent_assignments
                     WHERE agent_id=?1 AND status IN ('running','waiting')
                     ORDER BY CASE status WHEN 'waiting' THEN 0 ELSE 1 END,
                              created_at,assignment_id LIMIT 1",
                    [agent_id],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|error| format!("inspect reusable agent active work: {error}"))?;
            if active.as_deref() == Some(AgentAssignmentStatus::Waiting.as_str()) {
                AgentInstanceState::Waiting
            } else if active.is_some() {
                AgentInstanceState::Active
            } else {
                let queued = transaction
                    .query_row(
                        "SELECT EXISTS(
                        SELECT 1 FROM agent_assignments
                        WHERE agent_id=?1 AND status IN ('offered','accepted','queued')
                     )",
                        [agent_id],
                        |row| row.get::<_, bool>(0),
                    )
                    .map_err(|error| format!("inspect reusable agent queue: {error}"))?;
                if queued {
                    AgentInstanceState::Active
                } else {
                    AgentInstanceState::Idle
                }
            }
        }
        _ => AgentInstanceState::Active,
    };
    transaction
        .execute(
            "UPDATE agent_instances
             SET state=CASE
                    WHEN state IN ('closing','closed') THEN state
                    WHEN state='provisioning' AND ?2!='idle' THEN state
                    ELSE ?2
                 END,
                 updated_at=?3
             WHERE agent_id=?1",
            params![agent_id, state.as_str(), now],
        )
        .map_err(|error| format!("project reusable agent state: {error}"))?;
    Ok(())
}

/// Couple terminal worker truth to the single assignment owned by a direct
/// agent-runner bridge. Worker cancellation/failure has several persistence
/// entry points (explicit cancellation, lifecycle disablement, and recovered
/// execution failure); each calls this helper inside its existing transaction
/// so a terminal worker can never leave runnable agent work behind.
pub(crate) fn terminalize_direct_worker_assignment_in_tx(
    transaction: &Transaction<'_>,
    invocation_id: &str,
    target_status: AgentAssignmentStatus,
    error: &str,
    now: &str,
) -> Result<Option<String>, String> {
    if !matches!(
        target_status,
        AgentAssignmentStatus::Failed
            | AgentAssignmentStatus::Cancelled
            | AgentAssignmentStatus::TimedOut
    ) {
        return Err("direct worker terminal coupling requires a failure status".to_owned());
    }
    let Some((assignment_id, execution_id, agent_id, raw_status)) = transaction
        .query_row(
            "SELECT assignment.assignment_id,assignment.execution_id,
                    assignment.agent_id,assignment.status
             FROM direct_worker_agent_runs direct
             JOIN agent_assignments assignment USING(assignment_id)
             WHERE direct.worker_invocation_id=?1",
            [invocation_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            },
        )
        .optional()
        .map_err(|error| format!("load direct worker assignment for terminal coupling: {error}"))?
    else {
        return Ok(None);
    };
    let current_status = AgentAssignmentStatus::parse(&raw_status)
        .ok_or_else(|| format!("direct worker assignment has invalid status '{raw_status}'"))?;
    if current_status.is_terminal() {
        return Ok(Some(assignment_id));
    }
    let normalized_error = normalized_assignment_error(Some(error));
    let changed = transaction
        .execute(
            "UPDATE agent_assignments
             SET status=?2,result_id=NULL,result_json=NULL,result_reference_json=NULL,
                 error=?3,completed_at=?4,updated_at=?4
             WHERE assignment_id=?1
               AND status IN ('offered','accepted','queued','running','waiting')",
            params![assignment_id, target_status.as_str(), normalized_error, now,],
        )
        .map_err(|error| format!("terminalize direct worker assignment: {error}"))?;
    if changed != 1 {
        return Err(
            "direct worker assignment terminal coupling lost its compare-and-set".to_owned(),
        );
    }
    transaction
        .execute(
            "UPDATE agent_assignment_attempts
             SET status='interrupted',completed_at=?2,error=COALESCE(error,?3)
             WHERE assignment_id=?1 AND status='running'",
            params![assignment_id, now, error],
        )
        .map_err(|error| format!("interrupt direct worker assignment attempt: {error}"))?;
    update_agent_state_for_assignment(transaction, &agent_id, target_status, now)?;
    append_execution_event_in_tx(
        transaction,
        &execution_id,
        target_status.as_str(),
        &json!({
            "from":current_status.as_str(),
            "to":target_status.as_str(),
            "workerInvocationId":invocation_id,
            "coupledTerminal":true,
        }),
        now,
    )?;
    let execution = query_execution(transaction, &execution_id)?
        .ok_or_else(|| "direct worker terminal coupling lost its execution".to_owned())?;
    transaction
        .execute(
            "INSERT OR IGNORE INTO agent_outbox(
                outbox_id,deduplication_key,kind,agent_id,assignment_id,
                execution_id,payload_json,created_at
             ) VALUES (?1,?2,'result',?3,?4,?5,?6,?7)",
            params![
                format!("agent_outbox_{}", uuid::Uuid::now_v7()),
                format!("assignment-result:{assignment_id}"),
                agent_id,
                assignment_id,
                execution_id,
                encode_json(&json!({
                    "agentId":agent_id,
                    "assignmentId":assignment_id,
                    "executionId":execution_id,
                    "traceId":execution.trace_id,
                    "status":target_status.as_str(),
                    "resultId":null,
                    "resultReference":null,
                    "error":normalized_error,
                }))?,
                now,
            ],
        )
        .map_err(|error| format!("enqueue coupled direct worker result: {error}"))?;
    Ok(Some(assignment_id))
}

/// Preserve a direct worker's stable transcript/assignment across an
/// interrupted delivery attempt. Recovery reuses the same mapping rather than
/// provisioning an ad-hoc replacement child.
pub(crate) fn interrupt_direct_worker_assignment_in_tx(
    transaction: &Transaction<'_>,
    invocation_id: &str,
    reason: &str,
    now: &str,
) -> Result<(), String> {
    let Some((assignment_id, agent_id, raw_status)) = transaction
        .query_row(
            "SELECT assignment.assignment_id,assignment.agent_id,assignment.status
             FROM direct_worker_agent_runs direct
             JOIN agent_assignments assignment USING(assignment_id)
             WHERE direct.worker_invocation_id=?1",
            [invocation_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            },
        )
        .optional()
        .map_err(|error| format!("load interrupted direct worker assignment: {error}"))?
    else {
        return Ok(());
    };
    if raw_status == AgentAssignmentStatus::Running.as_str() {
        transaction
            .execute(
                "UPDATE agent_assignments SET status='queued',updated_at=?2
                 WHERE assignment_id=?1 AND status='running'",
                params![assignment_id, now],
            )
            .map_err(|error| format!("requeue interrupted direct worker assignment: {error}"))?;
        transaction
            .execute(
                "UPDATE agent_assignment_attempts
                 SET status='interrupted',completed_at=?2,error=COALESCE(error,?3)
                 WHERE assignment_id=?1 AND status='running'",
                params![assignment_id, now, reason],
            )
            .map_err(|error| format!("interrupt direct worker agent attempt: {error}"))?;
        transaction
            .execute(
                "UPDATE agent_instances SET state='active',updated_at=?2
                 WHERE agent_id=?1 AND state NOT IN ('provisioning','closing','closed')",
                params![agent_id, now],
            )
            .map_err(|error| format!("recover interrupted direct worker agent: {error}"))?;
    }
    Ok(())
}

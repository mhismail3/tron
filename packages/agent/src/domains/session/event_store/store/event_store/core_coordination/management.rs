//! Ownership-checked cancellation, configuration, close, retry, and promotion.

use std::collections::BTreeSet;

use serde::Serialize;

use super::*;

impl EventStore {
    pub(crate) fn cancel_core_agent_work(&self, request: &CancelRequest) -> Result<CancelOutcome> {
        validate_admission_key(&request.idempotency_key)?;
        if let Some(actor_agent_id) = request.actor_agent_id.as_deref() {
            validate_identifier("cancel actor agent id", actor_agent_id)?;
        }
        if let Some(reason) = request.reason.as_deref() {
            validate_bounded_text("cancellation reason", reason, MAX_MESSAGE_BYTES)?;
        }
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if let Some(outcome) =
                management_receipt_in_tx(&transaction, &request.idempotency_key, "cancel", request)?
            {
                transaction.commit()?;
                return Ok(outcome);
            }
            let candidates = match &request.target {
                CancelTarget::Assignment(assignment_id) => {
                    validate_identifier("cancel assignment id", assignment_id)?;
                    let assignment =
                        query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                            EventStoreError::InvalidOperation(format!(
                                "agent assignment '{assignment_id}' was not found"
                            ))
                        })?;
                    require_management_authority_in_tx(
                        &transaction,
                        request.actor_agent_id.as_deref(),
                        &assignment.agent_id,
                        true,
                    )?;
                    collect_owned_assignment_subtree_in_tx(
                        &transaction,
                        assignment_id,
                        request.actor_agent_id.as_deref(),
                    )?
                }
                CancelTarget::Agent(agent_id) => {
                    validate_identifier("cancel agent id", agent_id)?;
                    let _ = require_open_agent(&transaction, agent_id)?;
                    require_management_authority_in_tx(
                        &transaction,
                        request.actor_agent_id.as_deref(),
                        agent_id,
                        true,
                    )?;
                    let subtree = collect_management_subtree_in_tx(&transaction, agent_id)?;
                    collect_nonterminal_assignments_for_agents_in_tx(&transaction, &subtree)?
                }
            };
            let now = chrono::Utc::now().to_rfc3339();
            let mut cancelled_assignment_ids = Vec::new();
            let mut cancelled_agent_ids = BTreeSet::new();
            // Deep descendants terminalize first so any external wait sees
            // exact child evidence before its parent cancellation.
            for assignment_id in candidates.into_iter().rev() {
                let assignment =
                    query_assignment(&transaction, &assignment_id)?.ok_or_else(|| {
                        EventStoreError::Internal("cancelled assignment disappeared".to_owned())
                    })?;
                if assignment.status.is_terminal() {
                    continue;
                }
                validate_completion_transition(assignment.status, AssignmentStatus::Cancelled)?;
                transaction.execute(
                    "UPDATE agent_assignments
                     SET status='cancelled',completed_at=?2,updated_at=?2
                     WHERE assignment_id=?1 AND status NOT IN (
                       'completed','declined','failed','cancelled','timed_out','expired'
                     )",
                    params![assignment.assignment_id, now],
                )?;
                transaction.execute(
                    "UPDATE agent_assignment_attempts
                     SET status='failed',completed_at=?2,
                         error=COALESCE(?3,'cancelled by coordination owner')
                     WHERE assignment_id=?1 AND completed_at IS NULL",
                    params![assignment.assignment_id, now, request.reason],
                )?;
                cancel_assignment_waits_in_tx(&transaction, &assignment.assignment_id, &now)?;
                let result = store_result_in_tx(
                    &transaction,
                    &assignment.assignment_id,
                    AssignmentStatus::Cancelled,
                    None,
                    request.reason.as_deref(),
                    &now,
                )?;
                reconcile_and_schedule_result_in_tx(
                    &transaction,
                    &assignment,
                    AssignmentStatus::Cancelled,
                    &result.result_id,
                    request.reason.as_deref(),
                    &now,
                )?;
                cancelled_agent_ids.insert(assignment.agent_id);
                cancelled_assignment_ids.push(assignment.assignment_id);
            }
            for assignment_id in &cancelled_assignment_ids {
                transaction.execute(
                    "UPDATE agent_wake_intents
                     SET disposition='cancelled',lease_id=NULL,cancelled_at=?2,
                         last_error='target assignment was cancelled'
                     WHERE target_assignment_id=?1 AND disposition IN ('pending','leased')",
                    params![assignment_id, now],
                )?;
            }
            let outcome = CancelOutcome {
                cancelled_assignment_ids,
                cancelled_agent_ids: cancelled_agent_ids.into_iter().collect(),
            };
            store_management_receipt_in_tx(
                &transaction,
                &request.idempotency_key,
                "cancel",
                request,
                &outcome,
            )?;
            transaction.commit()?;
            Ok(outcome)
        })
    }

    pub(crate) fn configure_core_agent(&self, request: &ConfigureAgent) -> Result<AgentRecord> {
        validate_admission_key(&request.idempotency_key)?;
        validate_identifier("configure target agent id", &request.target_agent_id)?;
        validate_defaults(&request.defaults)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if let Some(outcome) = management_receipt_in_tx(
                &transaction,
                &request.idempotency_key,
                "configure",
                request,
            )? {
                transaction.commit()?;
                return Ok(outcome);
            }
            let agent = require_open_agent(&transaction, &request.target_agent_id)?;
            require_management_authority_in_tx(
                &transaction,
                request.actor_agent_id.as_deref(),
                &agent.agent_id,
                false,
            )?;
            require_agent_quiescent_in_tx(&transaction, &[agent.agent_id.clone()], false)?;
            if let Some(actor_id) = request.actor_agent_id.as_deref() {
                let actor = require_open_agent(&transaction, actor_id)?;
                if !json_grant_is_subset(
                    &request.defaults.capability_grant,
                    &actor.defaults.capability_grant,
                ) || !write_scopes_are_subset(
                    &request.defaults.write_scopes,
                    &actor.defaults.write_scopes,
                ) {
                    return Err(EventStoreError::InvalidOperation(
                        "agent configuration exceeds the manager's authority".to_owned(),
                    ));
                }
            }
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "UPDATE agents SET default_model=?2,default_reasoning_level=?3,
                    default_capability_grant_json=?4,default_write_scopes_json=?5,
                    default_limits_json=?6,updated_at=?7 WHERE agent_id=?1",
                params![
                    agent.agent_id,
                    request.defaults.model,
                    request.defaults.reasoning_level,
                    serde_json::to_string(&request.defaults.capability_grant)?,
                    serde_json::to_string(&request.defaults.write_scopes)?,
                    serde_json::to_string(&request.defaults.limits)?,
                    now,
                ],
            )?;
            let updated = query_agent(&transaction, &agent.agent_id)?.ok_or_else(|| {
                EventStoreError::Internal("configured agent disappeared".to_owned())
            })?;
            store_management_receipt_in_tx(
                &transaction,
                &request.idempotency_key,
                "configure",
                request,
                &updated,
            )?;
            transaction.commit()?;
            Ok(updated)
        })
    }

    pub(crate) fn close_core_agent(&self, request: &CloseAgent) -> Result<Vec<AgentRecord>> {
        validate_admission_key(&request.idempotency_key)?;
        validate_identifier("close target agent id", &request.target_agent_id)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if let Some(outcome) =
                management_receipt_in_tx(&transaction, &request.idempotency_key, "close", request)?
            {
                transaction.commit()?;
                return Ok(outcome);
            }
            let target = query_agent(&transaction, &request.target_agent_id)?.ok_or_else(|| {
                EventStoreError::InvalidOperation(format!(
                    "agent '{}' was not found",
                    request.target_agent_id
                ))
            })?;
            if target.lifecycle == AgentLifecycle::Closed {
                let outcome = vec![target];
                store_management_receipt_in_tx(
                    &transaction,
                    &request.idempotency_key,
                    "close",
                    request,
                    &outcome,
                )?;
                transaction.commit()?;
                return Ok(outcome);
            }
            if target.parent_agent_id.is_none() {
                return Err(EventStoreError::InvalidOperation(
                    "visible root agents are closed through session lifecycle".to_owned(),
                ));
            }
            require_management_authority_in_tx(
                &transaction,
                request.actor_agent_id.as_deref(),
                &target.agent_id,
                false,
            )?;
            let subtree = collect_management_subtree_in_tx(&transaction, &target.agent_id)?;
            require_agent_quiescent_in_tx(&transaction, &subtree, true)?;
            let now = chrono::Utc::now().to_rfc3339();
            for agent_id in subtree.iter().rev() {
                transaction.execute(
                    "UPDATE agents SET lifecycle='closed',closed_at=?2,updated_at=?2
                     WHERE agent_id=?1 AND lifecycle!='closed'",
                    params![agent_id, now],
                )?;
            }
            let mut closed = Vec::with_capacity(subtree.len());
            for agent_id in &subtree {
                closed.push(query_agent(&transaction, agent_id)?.ok_or_else(|| {
                    EventStoreError::Internal("closed agent disappeared".to_owned())
                })?);
            }
            store_management_receipt_in_tx(
                &transaction,
                &request.idempotency_key,
                "close",
                request,
                &closed,
            )?;
            transaction.commit()?;
            Ok(closed)
        })
    }

    pub(crate) fn retry_core_assignment(
        &self,
        request: &RetryAssignment,
    ) -> Result<AssignmentRecord> {
        validate_admission_key(&request.admission_key)?;
        validate_identifier("retry assignment id", &request.assignment_id)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let assignment =
                query_assignment(&transaction, &request.assignment_id)?.ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!(
                        "agent assignment '{}' was not found",
                        request.assignment_id
                    ))
                })?;
            if !matches!(
                assignment.status,
                AssignmentStatus::Failed
                    | AssignmentStatus::Cancelled
                    | AssignmentStatus::TimedOut
                    | AssignmentStatus::Expired
            ) {
                return Err(EventStoreError::InvalidOperation(
                    "only failed, cancelled, timed-out, or expired assignments may be retried"
                        .to_owned(),
                ));
            }
            require_management_authority_in_tx(
                &transaction,
                request.actor_agent_id.as_deref(),
                &assignment.agent_id,
                true,
            )?;
            let retry = admit_assignment_in_tx(
                &transaction,
                &NewAssignment {
                    admission_key: request.admission_key.clone(),
                    agent_id: assignment.agent_id,
                    requested_by_agent_id: request
                        .actor_agent_id
                        .clone()
                        .or(assignment.requested_by_agent_id),
                    parent_assignment_id: None,
                    retry_of_assignment_id: Some(assignment.assignment_id),
                    kind: AssignmentKind::Instruction,
                    task: assignment.task,
                    context: assignment.context,
                    trace_id: request.trace_id.clone(),
                    autonomous_hop: request.autonomous_hop,
                    model: assignment.model,
                    reasoning_level: assignment.reasoning_level,
                    capability_grant: Some(assignment.capability_snapshot),
                    write_scopes: Some(assignment.write_scopes_snapshot),
                    limits: Some(assignment.limits_snapshot),
                    deadline_at: None,
                },
            )?;
            transaction.commit()?;
            Ok(retry)
        })
    }

    /// Authenticated client operation. Model tools never receive this method.
    pub(crate) fn promote_core_agent(&self, request: &PromoteAgent) -> Result<AgentRecord> {
        validate_admission_key(&request.idempotency_key)?;
        validate_identifier("promote agent id", &request.agent_id)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if let Some(outcome) = management_receipt_in_tx(
                &transaction,
                &request.idempotency_key,
                "promote",
                request,
            )? {
                transaction.commit()?;
                return Ok(outcome);
            }
            let agent = query_agent(&transaction, &request.agent_id)?.ok_or_else(|| {
                EventStoreError::InvalidOperation(format!(
                    "agent '{}' was not found",
                    request.agent_id
                ))
            })?;
            if agent.visibility == AgentVisibility::Visible {
                store_management_receipt_in_tx(
                    &transaction,
                    &request.idempotency_key,
                    "promote",
                    request,
                    &agent,
                )?;
                transaction.commit()?;
                return Ok(agent);
            }
            if agent.lifecycle != AgentLifecycle::Open || agent.parent_agent_id.is_none() {
                return Err(EventStoreError::InvalidOperation(
                    "only an open nested agent may be promoted".to_owned(),
                ));
            }
            let subtree = collect_management_subtree_in_tx(&transaction, &agent.agent_id)?;
            require_agent_quiescent_in_tx(&transaction, &subtree, true)?;
            let session = SessionRepo::get_by_id(&transaction, &agent.transcript_session_id)?
                .ok_or_else(|| {
                    EventStoreError::SessionNotFound(agent.transcript_session_id.clone())
                })?;
            let mut tags = serde_json::from_str::<Vec<String>>(&session.tags).map_err(|error| {
                EventStoreError::InvalidOperation(format!(
                    "agent transcript has invalid tags: {error}"
                ))
            })?;
            if !tags.iter().any(|tag| tag == AGENT_SESSION_TAG) {
                return Err(EventStoreError::InvalidOperation(
                    "agent transcript is not nested".to_owned(),
                ));
            }
            tags.retain(|tag| tag != AGENT_SESSION_TAG);
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "UPDATE sessions SET tags=?2,last_activity_at=?3 WHERE id=?1",
                params![
                    agent.transcript_session_id,
                    serde_json::to_string(&tags)?,
                    now
                ],
            )?;
            transaction.execute(
                "INSERT OR IGNORE INTO agent_session_promotions(session_id,promoted_at)
                 VALUES (?1,?2)",
                params![agent.transcript_session_id, now],
            )?;
            transaction.execute(
                "UPDATE agents SET visibility='visible',management_owner_agent_id=NULL,
                    updated_at=?2 WHERE agent_id=?1 AND visibility='nested'",
                params![agent.agent_id, now],
            )?;
            let promoted = query_agent(&transaction, &agent.agent_id)?.ok_or_else(|| {
                EventStoreError::Internal("promoted agent disappeared".to_owned())
            })?;
            store_management_receipt_in_tx(
                &transaction,
                &request.idempotency_key,
                "promote",
                request,
                &promoted,
            )?;
            transaction.commit()?;
            Ok(promoted)
        })
    }
}

fn require_management_authority_in_tx(
    connection: &rusqlite::Connection,
    actor_agent_id: Option<&str>,
    target_agent_id: &str,
    allow_self: bool,
) -> Result<()> {
    let Some(actor_agent_id) = actor_agent_id else {
        return Ok(());
    };
    let _ = require_open_agent(connection, actor_agent_id)?;
    if allow_self && actor_agent_id == target_agent_id {
        return Ok(());
    }
    if actor_agent_id == target_agent_id
        || !agent_manages_in_tx(connection, actor_agent_id, target_agent_id)?
    {
        return Err(EventStoreError::InvalidOperation(
            "agent does not own management authority over the target".to_owned(),
        ));
    }
    Ok(())
}

fn collect_management_subtree_in_tx(
    connection: &rusqlite::Connection,
    agent_id: &str,
) -> Result<Vec<String>> {
    let mut statement = connection.prepare(
        "WITH RECURSIVE subtree(agent_id,depth) AS (
            SELECT agent_id,0 FROM agents WHERE agent_id=?1
            UNION ALL
            SELECT agent.agent_id,subtree.depth+1 FROM agents agent
            JOIN subtree ON agent.management_owner_agent_id=subtree.agent_id
            WHERE subtree.depth<16
         )
         SELECT agent_id FROM subtree ORDER BY depth,agent_id",
    )?;
    statement
        .query_map([agent_id], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(EventStoreError::from)
}

fn collect_owned_assignment_subtree_in_tx(
    connection: &rusqlite::Connection,
    assignment_id: &str,
    actor_agent_id: Option<&str>,
) -> Result<Vec<String>> {
    let mut statement = connection.prepare(
        "WITH RECURSIVE subtree(assignment_id,agent_id,depth) AS (
            SELECT assignment_id,agent_id,0 FROM agent_assignments WHERE assignment_id=?1
            UNION ALL
            SELECT assignment.assignment_id,assignment.agent_id,subtree.depth+1
            FROM agent_assignments assignment
            JOIN subtree ON assignment.parent_assignment_id=subtree.assignment_id
            WHERE subtree.depth<16
         )
         SELECT assignment_id,agent_id FROM subtree ORDER BY depth,assignment_id",
    )?;
    let candidates = statement
        .query_map([assignment_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut owned = Vec::new();
    for (assignment_id, agent_id) in candidates {
        let authorized = match actor_agent_id {
            None => true,
            Some(actor) => actor == agent_id || agent_manages_in_tx(connection, actor, &agent_id)?,
        };
        if authorized {
            owned.push(assignment_id);
        }
    }
    Ok(owned)
}

fn collect_nonterminal_assignments_for_agents_in_tx(
    connection: &rusqlite::Connection,
    agent_ids: &[String],
) -> Result<Vec<String>> {
    let mut assignments = Vec::new();
    for agent_id in agent_ids {
        let mut statement = connection.prepare(
            "SELECT assignment_id FROM agent_assignments
             WHERE agent_id=?1 AND status NOT IN (
               'completed','declined','failed','cancelled','timed_out','expired'
             ) ORDER BY causal_depth,created_at,assignment_id",
        )?;
        assignments.extend(
            statement
                .query_map([agent_id], |row| row.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?,
        );
    }
    Ok(assignments)
}

fn cancel_assignment_waits_in_tx(
    transaction: &rusqlite::Transaction<'_>,
    assignment_id: &str,
    now: &str,
) -> Result<()> {
    transaction.execute(
        "UPDATE coordination_wait_members SET disposition='released',resolved_at=?2
         WHERE disposition='pending' AND wait_id IN (
           SELECT wait_id FROM coordination_waits
           WHERE owner_assignment_id=?1 AND disposition='pending'
         )",
        params![assignment_id, now],
    )?;
    transaction.execute(
        "UPDATE coordination_waits SET disposition='cancelled',resolved_at=?2
         WHERE owner_assignment_id=?1 AND disposition='pending'",
        params![assignment_id, now],
    )?;
    Ok(())
}

fn require_agent_quiescent_in_tx(
    connection: &rusqlite::Connection,
    agent_ids: &[String],
    include_wakes: bool,
) -> Result<()> {
    for agent_id in agent_ids {
        let busy = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM agent_assignments
             WHERE agent_id=?1 AND status IN ('offered','queued','running','waiting'))",
            [agent_id],
            |row| row.get::<_, bool>(0),
        )?;
        let waiting = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM coordination_waits
             WHERE owner_agent_id=?1 AND disposition='pending')",
            [agent_id],
            |row| row.get::<_, bool>(0),
        )?;
        let waking = include_wakes
            && connection.query_row(
                "SELECT EXISTS(SELECT 1 FROM agent_wake_intents
                 WHERE target_agent_id=?1 AND disposition IN ('pending','leased'))",
                [agent_id],
                |row| row.get::<_, bool>(0),
            )?;
        if busy || waiting || waking {
            return Err(EventStoreError::InvalidOperation(format!(
                "agent '{agent_id}' is not quiescent"
            )));
        }
    }
    Ok(())
}

fn json_grant_is_subset(requested: &Value, ceiling: &Value) -> bool {
    match (requested, ceiling) {
        (Value::Object(requested), Value::Object(ceiling)) => {
            requested.iter().all(|(key, value)| {
                ceiling
                    .get(key)
                    .is_some_and(|ceiling| json_grant_is_subset(value, ceiling))
            })
        }
        (Value::Array(requested), Value::Array(ceiling)) => requested
            .iter()
            .all(|value| ceiling.iter().any(|candidate| candidate == value)),
        (Value::Bool(false), Value::Bool(_)) => true,
        _ => requested == ceiling,
    }
}

fn write_scopes_are_subset(requested: &[String], ceiling: &[String]) -> bool {
    requested.iter().all(|requested| {
        ceiling.iter().any(|ceiling| {
            requested == ceiling
                || requested
                    .strip_prefix(ceiling)
                    .is_some_and(|suffix| suffix.starts_with('/'))
        })
    })
}

fn management_receipt_in_tx<T: serde::de::DeserializeOwned, R: Serialize>(
    connection: &rusqlite::Connection,
    idempotency_key: &str,
    action: &str,
    request: &R,
) -> Result<Option<T>> {
    let stored = connection
        .query_row(
            "SELECT action,request_json,outcome_json FROM agent_management_receipts
             WHERE idempotency_key=?1",
            [idempotency_key],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((stored_action, stored_request, outcome)) = stored else {
        return Ok(None);
    };
    let request_json = serde_json::to_value(request)?;
    if stored_action != action || serde_json::from_str::<Value>(&stored_request)? != request_json {
        return Err(EventStoreError::InvalidOperation(
            "agent management idempotency conflict".to_owned(),
        ));
    }
    Ok(Some(serde_json::from_str(&outcome)?))
}

fn store_management_receipt_in_tx<R: Serialize, T: Serialize>(
    transaction: &rusqlite::Transaction<'_>,
    idempotency_key: &str,
    action: &str,
    request: &R,
    outcome: &T,
) -> Result<()> {
    transaction.execute(
        "INSERT INTO agent_management_receipts(
            idempotency_key,action,request_json,outcome_json,created_at
         ) VALUES (?1,?2,?3,?4,?5)",
        params![
            idempotency_key,
            action,
            serde_json::to_string(request)?,
            serde_json::to_string(outcome)?,
            chrono::Utc::now().to_rfc3339(),
        ],
    )?;
    Ok(())
}

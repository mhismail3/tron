//! Assignment transitions, attempts, execution events, and result custody.
//!
//! Terminal assignment truth and its result outbox commit together.

use super::*;

impl WorkerStore {
    /// Compare-and-set an assignment state and couple terminal truth to its
    /// result outbox in the same transaction.
    pub(crate) fn transition_agent_assignment(
        &self,
        request: &AgentAssignmentTransition,
    ) -> Result<AgentAssignmentRecord, String> {
        validate_runtime_identifier(&request.assignment_id, "assignment id", 256)?;
        validate_assignment_transition_payload(request)?;
        if !valid_assignment_transition(request.expected_status, request.target_status) {
            return Err(format!(
                "invalid agent assignment transition {} -> {}",
                request.expected_status.as_str(),
                request.target_status.as_str()
            ));
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent assignment transition: {error}"))?;
        let current = query_assignment(&transaction, &request.assignment_id)?
            .ok_or_else(|| format!("agent assignment '{}' was not found", request.assignment_id))?;
        if current.status == request.target_status {
            let expected_error = normalized_assignment_error(request.error.as_deref());
            if current.error != expected_error {
                return Err("agent assignment transition idempotency conflict".to_owned());
            }
            if let Some(expected_result) = request.result.as_ref() {
                let result_id = current.result_id.as_deref().ok_or_else(|| {
                    "completed agent assignment lost its durable result identity".to_owned()
                })?;
                let stored_result = resolve_agent_result_in_tx(&transaction, result_id)?
                    .ok_or_else(|| {
                        "completed agent assignment lost its durable result".to_owned()
                    })?;
                if &stored_result != expected_result {
                    return Err("agent assignment transition idempotency conflict".to_owned());
                }
            }
            transaction
                .commit()
                .map_err(|error| format!("commit idempotent agent transition read: {error}"))?;
            return Ok(current);
        }
        if current.status != request.expected_status {
            return Err(format!(
                "agent assignment '{}' is {}, expected {}",
                request.assignment_id,
                current.status.as_str(),
                request.expected_status.as_str()
            ));
        }
        if request.target_status.is_terminal()
            && execution_has_live_children(&transaction, &current.execution_id)?
        {
            return Err(format!(
                "agent assignment '{}' still owns live child executions",
                request.assignment_id
            ));
        }
        if request.target_status == AgentAssignmentStatus::Running {
            if coordination_trace_paused_for_execution_in_tx(&transaction, &current.execution_id)? {
                return Err(format!(
                    "AGENT_AUTONOMY_PAUSED: coordination trace for assignment '{}' is paused",
                    current.assignment_id
                ));
            }
            let another_active = transaction
                .query_row(
                    "SELECT EXISTS(
                        SELECT 1 FROM agent_assignments
                        WHERE agent_id=?1 AND assignment_id!=?2
                          AND status IN ('running','waiting')
                     )",
                    params![current.agent_id, current.assignment_id],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(|error| format!("inspect reusable agent active assignment: {error}"))?;
            if another_active {
                return Err(format!(
                    "agent '{}' already has a running or waiting assignment",
                    current.agent_id
                ));
            }
            if matches!(
                request.expected_status,
                AgentAssignmentStatus::Accepted | AgentAssignmentStatus::Queued
            ) {
                let next_assignment_id = transaction
                    .query_row(
                        "SELECT assignment_id FROM agent_assignments
                         WHERE agent_id=?1 AND status IN ('accepted','queued')
                           AND NOT EXISTS(
                            SELECT 1
                            FROM execution_nodes node
                            JOIN coordination_trace_states trace_state
                              ON trace_state.trace_id=node.trace_id
                             AND trace_state.state='paused'
                            WHERE node.execution_id=agent_assignments.execution_id
                           )
                         ORDER BY queue_ordinal,created_at,assignment_id LIMIT 1",
                        [&current.agent_id],
                        |row| row.get::<_, String>(0),
                    )
                    .map_err(|error| format!("select next reusable agent assignment: {error}"))?;
                if next_assignment_id != current.assignment_id {
                    return Err("agent assignments must start in priority/FIFO order".to_owned());
                }
            }
        }
        let now = chrono::Utc::now().to_rfc3339();
        let accepted_at =
            (request.target_status == AgentAssignmentStatus::Accepted).then_some(now.as_str());
        let started_at =
            (request.target_status == AgentAssignmentStatus::Running).then_some(now.as_str());
        let completed_at = request.target_status.is_terminal().then_some(now.as_str());
        let (result_id, stored_result, result_reference) = match request.result.as_ref() {
            Some(result) => {
                let result_id = format!("agent_result_{}", uuid::Uuid::now_v7());
                let (trace_id, root_session_id, workspace_id) = transaction
                    .query_row(
                        "SELECT node.trace_id,agent.root_session_id,agent.workspace_id
                         FROM execution_nodes node
                         JOIN agent_assignments assignment USING(execution_id)
                         JOIN agent_instances agent USING(agent_id)
                         WHERE assignment.assignment_id=?1",
                        [&current.assignment_id],
                        |row| {
                            Ok((
                                row.get::<_, String>(0)?,
                                row.get::<_, String>(1)?,
                                row.get::<_, String>(2)?,
                            ))
                        },
                    )
                    .map_err(|error| format!("load agent result scope: {error}"))?;
                let stored = crate::shared::storage::store_json_value(
                    &transaction,
                    result,
                    &crate::shared::storage::StorePayloadOptions::new(
                        "agent_assignment",
                        &result_id,
                        "result",
                        "durable",
                    )
                    .with_scope(
                        Some(trace_id),
                        Some(root_session_id),
                        Some(workspace_id),
                    ),
                )
                .map_err(|error| format!("store durable agent assignment result: {error:#}"))?;
                let reference = agent_result_reference_in_tx(
                    &transaction,
                    &result_id,
                    &current.assignment_id,
                    &current.agent_id,
                )?;
                (
                    Some(result_id),
                    Some(stored),
                    Some(encode_json(&reference)?),
                )
            }
            None => (None, None, None),
        };
        let error = normalized_assignment_error(request.error.as_deref());
        let changed = transaction
            .execute(
                "UPDATE agent_assignments
                 SET status=?3,
                     accepted_at=COALESCE(accepted_at,?4),
                     started_at=COALESCE(started_at,?5),
                     completed_at=?6,
                     result_id=?7,
                     result_json=?8,
                     result_reference_json=?9,
                     error=?10,
                     updated_at=?11
                 WHERE assignment_id=?1 AND status=?2",
                params![
                    request.assignment_id,
                    request.expected_status.as_str(),
                    request.target_status.as_str(),
                    accepted_at,
                    started_at,
                    completed_at,
                    result_id,
                    stored_result,
                    result_reference,
                    error,
                    now,
                ],
            )
            .map_err(|error| format!("transition agent assignment: {error}"))?;
        if changed != 1 {
            return Err("agent assignment transition lost a concurrent compare-and-set".to_owned());
        }
        update_agent_state_for_assignment(
            &transaction,
            &current.agent_id,
            request.target_status,
            &now,
        )?;
        append_execution_event_in_tx(
            &transaction,
            &current.execution_id,
            request.target_status.as_str(),
            &json!({
                "from": request.expected_status.as_str(),
                "to": request.target_status.as_str(),
            }),
            &now,
        )?;
        if request.target_status.is_terminal() {
            let execution = query_execution(&transaction, &current.execution_id)?
                .ok_or_else(|| "terminal assignment lost its execution node".to_owned())?;
            let payload = json!({
                "agentId": current.agent_id,
                "assignmentId": current.assignment_id,
                "executionId": current.execution_id,
                "traceId": execution.trace_id,
                "status": request.target_status.as_str(),
                "resultId": result_id,
                "resultReference": result_reference
                    .as_deref()
                    .map(serde_json::from_str::<Value>)
                    .transpose()
                    .map_err(|error| format!("decode agent result reference: {error}"))?,
                "error": error,
            });
            transaction
                .execute(
                    "INSERT OR IGNORE INTO agent_outbox(
                        outbox_id,deduplication_key,kind,agent_id,assignment_id,
                        execution_id,payload_json,created_at
                     ) VALUES (?1,?2,'result',?3,?4,?5,?6,?7)",
                    params![
                        format!("agent_outbox_{}", uuid::Uuid::now_v7()),
                        format!("assignment-result:{}", current.assignment_id),
                        current.agent_id,
                        current.assignment_id,
                        current.execution_id,
                        encode_json(&payload)?,
                        now,
                    ],
                )
                .map_err(|error| format!("enqueue terminal agent result: {error}"))?;
        }
        let record = query_assignment(&transaction, &request.assignment_id)?
            .ok_or_else(|| "transitioned agent assignment disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit agent assignment transition: {error}"))?;
        record_agent_assignment_transition_metrics(&current, &record);
        Ok(record)
    }

    pub(crate) fn begin_agent_assignment_attempt(
        &self,
        assignment_id: &str,
        run_id: Option<&str>,
        baseline_event_sequence: i64,
    ) -> Result<AgentAssignmentAttemptRecord, String> {
        validate_runtime_identifier(assignment_id, "assignment id", 256)?;
        if let Some(run_id) = run_id {
            validate_runtime_identifier(run_id, "agent run id", 256)?;
        }
        if baseline_event_sequence < 0 {
            return Err("agent attempt baseline event sequence must be nonnegative".to_owned());
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent assignment attempt: {error}"))?;
        let assignment = query_assignment(&transaction, assignment_id)?
            .ok_or_else(|| format!("agent assignment '{assignment_id}' was not found"))?;
        if assignment.status != AgentAssignmentStatus::Running {
            return Err(format!(
                "agent assignment '{assignment_id}' must be running before an attempt starts"
            ));
        }
        let running = query_running_attempt(&transaction, assignment_id)?;
        if let Some(record) = running {
            if record.run_id.as_deref() == run_id
                && record.baseline_event_sequence == baseline_event_sequence
            {
                transaction
                    .commit()
                    .map_err(|error| format!("commit idempotent agent attempt read: {error}"))?;
                return Ok(record);
            }
            return Err(format!(
                "agent assignment '{assignment_id}' already has a running attempt"
            ));
        }
        let attempt_number = transaction
            .query_row(
                "SELECT COALESCE(MAX(attempt_number),0)+1
                 FROM agent_assignment_attempts WHERE assignment_id=?1",
                [assignment_id],
                |row| row.get::<_, u32>(0),
            )
            .map_err(|error| format!("number agent assignment attempt: {error}"))?;
        let attempt_id = format!("agent_attempt_{}", uuid::Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        transaction
            .execute(
                "INSERT INTO agent_assignment_attempts(
                    attempt_id,assignment_id,attempt_number,status,run_id,
                    baseline_event_sequence,started_at
                 ) VALUES (?1,?2,?3,'running',?4,?5,?6)",
                params![
                    attempt_id,
                    assignment_id,
                    attempt_number,
                    run_id,
                    baseline_event_sequence,
                    now
                ],
            )
            .map_err(|error| format!("insert agent assignment attempt: {error}"))?;
        append_execution_event_in_tx(
            &transaction,
            &assignment.execution_id,
            "attempt_started",
            &json!({
                "attemptId":attempt_id,
                "attemptNumber":attempt_number,
                "baselineEventSequence":baseline_event_sequence,
            }),
            &now,
        )?;
        let record = query_attempt(&transaction, &attempt_id)?
            .ok_or_else(|| "agent assignment attempt disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit agent assignment attempt: {error}"))?;
        Ok(record)
    }

    pub(crate) fn finish_agent_assignment_attempt(
        &self,
        attempt_id: &str,
        status: &str,
        error: Option<&str>,
    ) -> Result<AgentAssignmentAttemptRecord, String> {
        if !matches!(status, "completed" | "failed" | "interrupted" | "waiting") {
            return Err("agent attempt terminal status is invalid".to_owned());
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent attempt completion: {error}"))?;
        let current = query_attempt(&transaction, attempt_id)?
            .ok_or_else(|| format!("agent attempt '{attempt_id}' was not found"))?;
        if current.status != "running" {
            if current.status == status {
                transaction.commit().map_err(|error| {
                    format!("commit idempotent attempt completion read: {error}")
                })?;
                return Ok(current);
            }
            return Err(format!("agent attempt '{attempt_id}' is already terminal"));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let error = error.map(|value| value.chars().take(MAX_ERROR_BYTES).collect::<String>());
        transaction
            .execute(
                "UPDATE agent_assignment_attempts
                 SET status=?2,completed_at=?3,error=?4
                 WHERE attempt_id=?1 AND status='running'",
                params![attempt_id, status, now, error],
            )
            .map_err(|error| format!("complete agent assignment attempt: {error}"))?;
        let execution_id = transaction
            .query_row(
                "SELECT assignment.execution_id
                 FROM agent_assignment_attempts attempt
                 JOIN agent_assignments assignment USING(assignment_id)
                 WHERE attempt.attempt_id=?1",
                [attempt_id],
                |row| row.get::<_, String>(0),
            )
            .map_err(|error| format!("load completed attempt execution: {error}"))?;
        append_execution_event_in_tx(
            &transaction,
            &execution_id,
            "attempt_finished",
            &json!({"attemptId":attempt_id,"status":status}),
            &now,
        )?;
        let record = query_attempt(&transaction, attempt_id)?
            .ok_or_else(|| "completed agent attempt disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit agent attempt completion: {error}"))?;
        Ok(record)
    }

    /// Interrupt every running attempt owned by one assignment in a single
    /// writer transaction. Normal admission permits only one running attempt,
    /// but cancellation and recovery must repair exact durable truth rather
    /// than trusting that process-local invariant after a crash or migration.
    pub(crate) fn interrupt_running_agent_assignment_attempts(
        &self,
        assignment_id: &str,
        reason: &str,
    ) -> Result<usize, String> {
        validate_runtime_identifier(assignment_id, "assignment id", 256)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent attempt interruption: {error}"))?;
        let assignment = query_assignment(&transaction, assignment_id)?
            .ok_or_else(|| format!("agent assignment '{assignment_id}' was not found"))?;
        let attempt_ids = {
            let mut statement = transaction
                .prepare(
                    "SELECT attempt_id FROM agent_assignment_attempts
                     WHERE assignment_id=?1 AND status='running'
                     ORDER BY attempt_number,attempt_id",
                )
                .map_err(|error| format!("prepare running agent attempts: {error}"))?;
            statement
                .query_map([assignment_id], |row| row.get::<_, String>(0))
                .map_err(|error| format!("query running agent attempts: {error}"))?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(|error| format!("decode running agent attempts: {error}"))?
        };
        let now = chrono::Utc::now().to_rfc3339();
        let error = normalized_assignment_error(Some(reason));
        let mut interrupted = 0;
        for attempt_id in attempt_ids {
            let changed = transaction
                .execute(
                    "UPDATE agent_assignment_attempts
                     SET status='interrupted',completed_at=?2,error=?3
                     WHERE attempt_id=?1 AND status='running'",
                    params![attempt_id, now, error],
                )
                .map_err(|error| format!("interrupt running agent attempt: {error}"))?;
            if changed == 1 {
                append_execution_event_in_tx(
                    &transaction,
                    &assignment.execution_id,
                    "attempt_finished",
                    &json!({"attemptId":attempt_id,"status":"interrupted"}),
                    &now,
                )?;
                interrupted += 1;
            }
        }
        transaction
            .commit()
            .map_err(|error| format!("commit agent attempt interruption: {error}"))?;
        Ok(interrupted)
    }

    pub(crate) fn list_agent_assignment_attempts(
        &self,
        assignment_id: &str,
        limit: usize,
    ) -> Result<Vec<AgentAssignmentAttemptRecord>, String> {
        validate_runtime_identifier(assignment_id, "assignment id", 256)?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {ATTEMPT_COLUMNS} FROM agent_assignment_attempts
                 WHERE assignment_id=?1 ORDER BY attempt_number DESC LIMIT ?2"
            ))
            .map_err(|error| format!("prepare agent assignment attempts: {error}"))?;
        statement
            .query_map(
                params![
                    assignment_id,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200)
                ],
                map_attempt,
            )
            .map_err(|error| format!("query agent assignment attempts: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode agent assignment attempts: {error}"))
    }

    pub(crate) fn list_agent_execution_events(
        &self,
        execution_id: &str,
        after_sequence: Option<u64>,
        limit: usize,
    ) -> Result<Vec<AgentExecutionEventRecord>, String> {
        validate_runtime_identifier(execution_id, "execution id", 256)?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT event_id,execution_id,sequence,kind,details_json,occurred_at
                 FROM agent_execution_events
                 WHERE execution_id=?1 AND (?2 IS NULL OR sequence>?2)
                 ORDER BY sequence LIMIT ?3",
            )
            .map_err(|error| format!("prepare agent execution events: {error}"))?;
        statement
            .query_map(
                params![
                    execution_id,
                    after_sequence,
                    i64::try_from(limit.clamp(1, 200)).unwrap_or(200),
                ],
                map_execution_event,
            )
            .map_err(|error| format!("query agent execution events: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode agent execution events: {error}"))
    }
}

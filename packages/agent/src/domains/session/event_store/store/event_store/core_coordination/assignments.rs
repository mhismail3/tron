//! FIFO assignment admission, attempts, lifecycle, and immutable results.

use super::*;

impl EventStore {
    /// Admit another piece of work for an existing reusable agent.
    pub(crate) fn admit_core_assignment(
        &self,
        request: &NewAssignment,
    ) -> Result<AssignmentRecord> {
        validate_new_assignment(request)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let assignment = admit_assignment_in_tx(&transaction, request)?;
            transaction.commit()?;
            Ok(assignment)
        })
    }

    pub(crate) fn respond_to_core_assignment_offer(
        &self,
        request: &RespondToOffer,
    ) -> Result<AssignmentRecord> {
        validate_identifier("offer actor agent id", &request.actor_agent_id)?;
        validate_identifier("assignment id", &request.assignment_id)?;
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
            if assignment.agent_id != request.actor_agent_id {
                return Err(EventStoreError::InvalidOperation(
                    "only the offered agent may accept or decline its assignment".to_owned(),
                ));
            }
            if (request.accept && assignment.status == AssignmentStatus::Queued)
                || (!request.accept && assignment.status == AssignmentStatus::Declined)
            {
                transaction.commit()?;
                return Ok(assignment);
            }
            if assignment.status != AssignmentStatus::Offered {
                return Err(EventStoreError::InvalidOperation(format!(
                    "assignment offer is {}, not offered",
                    assignment.status.as_str()
                )));
            }
            let now = chrono::Utc::now().to_rfc3339();
            if request.accept {
                transaction.execute(
                    "UPDATE agent_assignments
                     SET status='queued',accepted_at=?2,updated_at=?2
                     WHERE assignment_id=?1 AND status='offered'",
                    params![request.assignment_id, now],
                )?;
            } else {
                transaction.execute(
                    "UPDATE agent_assignments
                     SET status='declined',completed_at=?2,updated_at=?2
                     WHERE assignment_id=?1 AND status='offered'",
                    params![request.assignment_id, now],
                )?;
                let _ = store_result_in_tx(
                    &transaction,
                    &request.assignment_id,
                    AssignmentStatus::Declined,
                    None,
                    None,
                    &now,
                )?;
                reconcile_and_schedule_result_in_tx(
                    &transaction,
                    &assignment,
                    AssignmentStatus::Declined,
                    &stable_id("agent_result", &[&request.assignment_id]),
                    None,
                    &now,
                )?;
            }
            let updated =
                query_assignment(&transaction, &request.assignment_id)?.ok_or_else(|| {
                    EventStoreError::Internal("assignment offer disappeared".to_owned())
                })?;
            transaction.commit()?;
            Ok(updated)
        })
    }

    /// Claim exactly the FIFO head for an idle agent and durably start its next
    /// attempt in the same transaction.
    pub(crate) fn claim_next_core_assignment(
        &self,
        request: &ClaimAssignment,
    ) -> Result<Option<ClaimedAssignment>> {
        validate_identifier("agent id", &request.agent_id)?;
        validate_identifier("run id", &request.run_id)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let _ = require_open_agent(&transaction, &request.agent_id)?;
            let active = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM agent_assignments
                 WHERE agent_id=?1 AND status IN ('running','waiting'))",
                [&request.agent_id],
                |row| row.get::<_, bool>(0),
            )?;
            if active {
                transaction.commit()?;
                return Ok(None);
            }
            let Some(assignment) = query_next_queued_assignment(&transaction, &request.agent_id)?
            else {
                transaction.commit()?;
                return Ok(None);
            };
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "UPDATE agent_assignments
                 SET status='running',started_at=COALESCE(started_at,?2),updated_at=?2
                 WHERE assignment_id=?1 AND status='queued'",
                params![assignment.assignment_id, now],
            )?;
            let attempt_number = transaction.query_row(
                "SELECT COALESCE(MAX(attempt_number),0)+1
                 FROM agent_assignment_attempts WHERE assignment_id=?1",
                [&assignment.assignment_id],
                |row| row.get::<_, u32>(0),
            )?;
            let attempt_id = stable_id(
                "agent_attempt",
                &[&assignment.assignment_id, &attempt_number.to_string()],
            );
            transaction.execute(
                "INSERT INTO agent_assignment_attempts(
                    attempt_id,assignment_id,attempt_number,status,run_id,
                    baseline_event_sequence,started_at
                 ) VALUES (?1,?2,?3,'running',?4,?5,?6)",
                params![
                    attempt_id,
                    assignment.assignment_id,
                    attempt_number,
                    request.run_id,
                    request.baseline_event_sequence,
                    now,
                ],
            )?;
            let claimed = ClaimedAssignment {
                assignment: query_assignment(&transaction, &assignment.assignment_id)?.ok_or_else(
                    || EventStoreError::Internal("claimed assignment disappeared".to_owned()),
                )?,
                attempt: query_attempt(&transaction, &attempt_id)?.ok_or_else(|| {
                    EventStoreError::Internal("assignment attempt disappeared".to_owned())
                })?,
            };
            transaction.commit()?;
            Ok(Some(claimed))
        })
    }

    /// Agent Execution calls this after handling a wake that interrupted a
    /// parked assignment. A still-pending explicit wait deterministically
    /// reparks the same attempt; a resolved/cancelled wait leaves it runnable.
    pub(crate) fn reconcile_core_assignment_parking(
        &self,
        assignment_id: &str,
    ) -> Result<AssignmentRecord> {
        validate_identifier("assignment id", assignment_id)?;
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let assignment = query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                EventStoreError::InvalidOperation(format!(
                    "agent assignment '{assignment_id}' was not found"
                ))
            })?;
            if !matches!(
                assignment.status,
                AssignmentStatus::Running | AssignmentStatus::Waiting
            ) {
                return Err(EventStoreError::InvalidOperation(format!(
                    "cannot reconcile parking for {} assignment",
                    assignment.status.as_str()
                )));
            }
            let has_pending_wait = transaction.query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM coordination_waits
                    WHERE owner_assignment_id=?1 AND disposition='pending'
                 )",
                [assignment_id],
                |row| row.get::<_, bool>(0),
            )?;
            let target = if has_pending_wait {
                AssignmentStatus::Waiting
            } else {
                AssignmentStatus::Running
            };
            let now = chrono::Utc::now().to_rfc3339();
            set_active_assignment_state_in_tx(&transaction, &assignment, target, &now)?;
            let updated = query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                EventStoreError::Internal("reconciled assignment disappeared".to_owned())
            })?;
            transaction.commit()?;
            Ok(updated)
        })
    }

    /// Commit terminal assignment state, immutable result custody, wait fan-in
    /// reconciliation, and automatic/aggregate wake decisions atomically.
    pub(crate) fn complete_core_assignment(
        &self,
        request: &CompleteAssignment,
    ) -> Result<AgentResultRecord> {
        validate_identifier("assignment id", &request.assignment_id)?;
        if let Some(error) = request.error.as_deref() {
            validate_bounded_text("assignment error", error, MAX_MESSAGE_BYTES)?;
        }
        if let Some(payload) = request.payload.as_ref() {
            validate_json_size("assignment result", payload, MAX_CONTEXT_BYTES * 16)?;
        }
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
            let target_status = request.terminal_status.as_status();
            if let Some(existing) =
                query_result_by_assignment(&transaction, &request.assignment_id)?
            {
                let record = load_result(&transaction, existing)?;
                if record.terminal_status != target_status
                    || record.payload != request.payload
                    || record.error != request.error
                {
                    return Err(EventStoreError::InvalidOperation(
                        "assignment completion idempotency conflict".to_owned(),
                    ));
                }
                transaction.commit()?;
                return Ok(record);
            }
            validate_completion_transition(assignment.status, target_status)?;
            let active_descendant = transaction.query_row(
                "WITH RECURSIVE descendants(assignment_id) AS (
                    SELECT assignment_id FROM agent_assignments WHERE parent_assignment_id=?1
                    UNION ALL
                    SELECT child.assignment_id FROM agent_assignments child
                    JOIN descendants parent ON child.parent_assignment_id=parent.assignment_id
                 )
                 SELECT EXISTS(
                    SELECT 1 FROM agent_assignments JOIN descendants USING(assignment_id)
                    WHERE status IN ('offered','queued','running','waiting')
                 )",
                [&request.assignment_id],
                |row| row.get::<_, bool>(0),
            )?;
            if active_descendant {
                return Err(EventStoreError::InvalidOperation(
                    "assignment cannot terminalize while it owns active descendants".to_owned(),
                ));
            }
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
                "UPDATE agent_assignments
                 SET status=?2,completed_at=?3,updated_at=?3
                 WHERE assignment_id=?1",
                params![request.assignment_id, target_status.as_str(), now],
            )?;
            let attempt_status = if target_status == AssignmentStatus::Completed {
                "completed"
            } else {
                "failed"
            };
            transaction.execute(
                "UPDATE agent_assignment_attempts
                 SET status=?2,completed_at=?3,error=?4
                 WHERE assignment_id=?1 AND completed_at IS NULL",
                params![request.assignment_id, attempt_status, now, request.error],
            )?;
            let result = store_result_in_tx(
                &transaction,
                &request.assignment_id,
                target_status,
                request.payload.as_ref(),
                request.error.as_deref(),
                &now,
            )?;
            reconcile_and_schedule_result_in_tx(
                &transaction,
                &assignment,
                target_status,
                &result.result_id,
                request.error.as_deref(),
                &now,
            )?;
            let record = load_result(&transaction, result)?;
            transaction.commit()?;
            Ok(record)
        })
    }
    pub(crate) fn core_agent_result(&self, result_id: &str) -> Result<Option<AgentResultRecord>> {
        validate_identifier("result id", result_id)?;
        let connection = self.conn()?;
        query_result(&connection, result_id)?
            .map(|stored| load_result(&connection, stored))
            .transpose()
    }
}

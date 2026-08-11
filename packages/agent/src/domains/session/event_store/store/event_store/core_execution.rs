//! Durable scheduling and recovery custody for core Agent Execution.
//!
//! This module deliberately contains no provider, WorkerStore, WorkerRuntime,
//! role, or execution-node behavior. It selects accepted FIFO work, opens and
//! closes restartable attempts, and repairs interrupted process-local custody
//! while preserving stable agent, assignment, and transcript identities.

use rusqlite::{OptionalExtension, params};

use crate::domains::agent::coordination::{
    AgentDefaults, AgentLifecycle, AgentRecord, AgentVisibility, AssignmentAttemptRecord,
    AssignmentKind, AssignmentRecord, AssignmentStatus, ClaimedAssignment, WakeIntentRecord,
};
use crate::domains::agent::execution::{AgentExecutionRecovery, AssignmentExecutionCandidate};
use crate::domains::session::event_store::AgentMessageMetadataRecord;
use crate::domains::session::event_store::errors::{EventStoreError, Result};

use super::EventStore;

const AGENT_COLUMNS: &str = "
    agent_id,transcript_session_id,root_agent_id,workspace_id,parent_agent_id,
    management_owner_agent_id,name,visibility,lifecycle,default_model,
    default_reasoning_level,default_capability_grant_json,default_write_scopes_json,
    default_limits_json,created_at,updated_at,closed_at
";
const ASSIGNMENT_COLUMNS: &str = "
    assignment_id,admission_key,agent_id,requested_by_agent_id,parent_assignment_id,
    retry_of_assignment_id,kind,status,queue_ordinal,trace_id,autonomous_hop,causal_depth,
    causal_ordinal,task,context_json,model,reasoning_level,capability_snapshot_json,
    write_scopes_snapshot_json,limits_snapshot_json,deadline_at,created_at,
    accepted_at,started_at,completed_at,updated_at
";
const ATTEMPT_COLUMNS: &str = "
    attempt_id,assignment_id,attempt_number,status,run_id,baseline_event_sequence,
    started_at,completed_at,error
";
const WAKE_COLUMNS: &str = "
    wake_id,idempotency_key,target_agent_id,target_session_id,target_assignment_id,
    cause_kind,cause_id,trace_id,autonomous_hop,materialized_message_id,
    priority,disposition,not_before,lease_id,delivered_by_lease_id,lease_count,last_error,
    created_at,leased_at,delivered_at,cancelled_at
";

impl EventStore {
    pub(crate) fn core_agent_record(&self, agent_id: &str) -> Result<Option<AgentRecord>> {
        let connection = self.conn()?;
        query_agent(&connection, agent_id)
    }

    pub(crate) fn core_assignment_record(
        &self,
        assignment_id: &str,
    ) -> Result<Option<AssignmentRecord>> {
        let connection = self.conn()?;
        query_assignment(&connection, assignment_id)
    }

    pub(crate) fn latest_core_assignment_attempt(
        &self,
        assignment_id: &str,
    ) -> Result<Option<AssignmentAttemptRecord>> {
        let connection = self.conn()?;
        query_latest_attempt(&connection, assignment_id)
    }

    /// Unobserved semantic messages eligible for this exact provider boundary.
    /// Assignment-linked evidence never leaks into unrelated queued work.
    /// Materialized rows remain eligible until a complete assistant/tool/turn
    /// lifecycle proves that a provider consumed them.
    pub(crate) fn core_messages_for_boundary(
        &self,
        target_session_id: &str,
        active_assignment_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<AgentMessageMetadataRecord>> {
        let mut messages = Vec::new();
        let mut offset = 0_usize;
        loop {
            let page = self.unobserved_agent_message_page(target_session_id, offset, 200)?;
            let page_len = page.items.len();
            messages.extend(page.items.into_iter().filter(|message| {
                message.assignment_id.is_none()
                    || message.assignment_id.as_deref() == active_assignment_id
            }));
            offset = offset.saturating_add(page_len);
            if page_len == 0 || u64::try_from(offset).unwrap_or(u64::MAX) >= page.total {
                break;
            }
        }
        messages.sort_by(|left, right| {
            left.created_at
                .cmp(&right.created_at)
                .then_with(|| left.channel_id.cmp(&right.channel_id))
                .then_with(|| left.channel_sequence.cmp(&right.channel_sequence))
                .then_with(|| left.message_id.cmp(&right.message_id))
        });
        messages.truncate(limit.clamp(1, 64));
        Ok(messages)
    }

    /// Bind one wake to the exact semantic message that represents it at the
    /// provider boundary. Crash after message insertion but before this CAS is
    /// repaired by the message idempotency key and this replay-safe binding.
    pub(crate) fn bind_core_wake_message(&self, wake_id: &str, message_id: &str) -> Result<bool> {
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let wake = query_wake(&transaction, wake_id)?.ok_or_else(|| {
                EventStoreError::InvalidOperation(format!("agent wake '{wake_id}' was not found"))
            })?;
            if wake.materialized_message_id.as_deref() == Some(message_id) {
                transaction.commit()?;
                return Ok(false);
            }
            if wake.materialized_message_id.is_some() {
                return Err(EventStoreError::InvalidOperation(
                    "agent wake is already bound to another semantic message".to_owned(),
                ));
            }
            let valid_message = transaction.query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM agent_message_metadata
                   WHERE message_id=?1 AND target_agent_id=?2 AND target_session_id=?3
                     AND disposition!='cancelled'
                 )",
                params![message_id, wake.target_agent_id, wake.target_session_id],
                |row| row.get::<_, bool>(0),
            )?;
            if !valid_message || (wake.cause_kind == "message" && wake.cause_id != message_id) {
                return Err(EventStoreError::InvalidOperation(
                    "wake semantic-message binding does not match its durable target/cause"
                        .to_owned(),
                ));
            }
            let changed = transaction.execute(
                "UPDATE agent_wake_intents SET materialized_message_id=?2
                 WHERE wake_id=?1 AND materialized_message_id IS NULL",
                params![wake_id, message_id],
            )?;
            transaction.commit()?;
            Ok(changed == 1)
        })
    }

    pub(crate) fn core_wake_record(&self, wake_id: &str) -> Result<Option<WakeIntentRecord>> {
        let connection = self.conn()?;
        query_wake(&connection, wake_id)
    }

    /// Atomically prove that a complete provider turn observed the exact
    /// semantic messages and terminalize their bound wakes. This single commit
    /// closes the crash boundary between transcript observation and wake
    /// acknowledgement, including result/wait wakes whose cause id is not a
    /// message id.
    pub(crate) fn observe_core_agent_messages_at_boundary(
        &self,
        target_session_id: &str,
        message_ids: &[String],
    ) -> Result<usize> {
        if message_ids.is_empty() {
            return Ok(0);
        }
        self.with_session_write_lock(target_session_id, || {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let now = chrono::Utc::now().to_rfc3339();
            let mut observed = 0;
            for message_id in message_ids {
                let changed = transaction.execute(
                    "UPDATE agent_message_metadata
                     SET disposition='observed',observed_at=?3
                     WHERE message_id=?1 AND target_session_id=?2
                       AND disposition='materialized'",
                    params![message_id, target_session_id, now],
                )?;
                if changed == 0 {
                    continue;
                }
                observed += changed;
                let boundary_key = format!("safe-boundary:{message_id}");
                transaction.execute(
                    "UPDATE agent_wake_intents
                     SET disposition='delivered',
                         delivered_by_lease_id=COALESCE(lease_id,?3),
                         lease_id=NULL,leased_at=NULL,delivered_at=?4,last_error=NULL
                     WHERE target_session_id=?1
                       AND (materialized_message_id=?2
                            OR (cause_kind='message' AND cause_id=?2))
                       AND disposition IN ('pending','leased')",
                    params![target_session_id, message_id, boundary_key, now],
                )?;
                transaction.execute(
                    "UPDATE agent_assignments SET status='running',updated_at=?2
                     WHERE status='waiting' AND assignment_id IN (
                       SELECT target_assignment_id FROM agent_wake_intents
                       WHERE target_session_id=?1
                         AND (materialized_message_id=?3
                              OR (cause_kind='message' AND cause_id=?3))
                         AND disposition='delivered'
                     )",
                    params![target_session_id, now, message_id],
                )?;
            }
            transaction.commit()?;
            Ok(observed)
        })
    }

    pub(crate) fn deliver_core_wake_at_boundary(&self, wake_id: &str) -> Result<bool> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            let now = chrono::Utc::now().to_rfc3339();
            connection
                .execute(
                    "UPDATE agent_wake_intents
                     SET disposition='delivered',
                         delivered_by_lease_id=COALESCE(lease_id,?3),
                         lease_id=NULL,leased_at=NULL,
                         delivered_at=?2,last_error=NULL
                     WHERE wake_id=?1 AND disposition IN ('pending','leased')",
                    params![wake_id, now, format!("safe-boundary:{wake_id}")],
                )
                .map(|changed| changed == 1)
                .map_err(EventStoreError::from)
        })
    }

    pub(crate) fn core_assignment_has_active_descendants(
        &self,
        assignment_id: &str,
    ) -> Result<bool> {
        let connection = self.conn()?;
        connection
            .query_row(
                "WITH RECURSIVE descendants(assignment_id) AS (
                   SELECT assignment_id FROM agent_assignments
                   WHERE parent_assignment_id=?1
                   UNION ALL
                   SELECT child.assignment_id FROM agent_assignments child
                   JOIN descendants parent
                     ON child.parent_assignment_id=parent.assignment_id
                 )
                 SELECT EXISTS(
                   SELECT 1 FROM agent_assignments JOIN descendants USING(assignment_id)
                   WHERE status IN ('offered','queued','running','waiting')
                 )",
                [assignment_id],
                |row| row.get(0),
            )
            .map_err(EventStoreError::from)
    }

    /// Return independent bounded lanes for active recovery and fresh FIFO
    /// work. A full page of parked assignments must never hide a later queued
    /// head (and a burst of queued work must not hide restart repair).
    ///
    /// Queued selection considers accepted work only: unresolved offers are
    /// actionable conversation but do not block an owner/operator instruction
    /// from running.
    pub(crate) fn core_execution_candidates(
        &self,
        limit: usize,
    ) -> Result<Vec<AssignmentExecutionCandidate>> {
        let connection = self.conn()?;
        let bounded = i64::try_from(limit.clamp(1, 256)).unwrap_or(256);
        let qualified_columns = qualified_assignment_columns("assignment");
        let mut active_statement = connection.prepare(&format!(
            "SELECT {qualified_columns} FROM agent_assignments assignment
             JOIN agents agent ON agent.agent_id=assignment.agent_id
             WHERE agent.lifecycle='open'
               AND assignment.status IN ('running','waiting')
             ORDER BY CASE assignment.status WHEN 'running' THEN 0 ELSE 1 END,
                      assignment.updated_at,assignment.queue_ordinal,
                      assignment.assignment_id
             LIMIT ?1"
        ))?;
        let mut assignments = active_statement
            .query_map([bounded], map_assignment)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut queued_statement = connection.prepare(&format!(
            "SELECT {qualified_columns} FROM agent_assignments assignment
             JOIN agents agent ON agent.agent_id=assignment.agent_id
             WHERE agent.lifecycle='open' AND assignment.status='queued'
               AND NOT EXISTS(
                 SELECT 1 FROM agent_assignments active
                 WHERE active.agent_id=assignment.agent_id
                   AND active.status IN ('running','waiting')
               )
               AND NOT EXISTS(
                 SELECT 1 FROM agent_assignments earlier
                 WHERE earlier.agent_id=assignment.agent_id
                   AND earlier.status='queued'
                   AND earlier.queue_ordinal<assignment.queue_ordinal
               )
             ORDER BY assignment.queue_ordinal,assignment.created_at,
                      assignment.assignment_id
             LIMIT ?1"
        ))?;
        assignments.extend(
            queued_statement
                .query_map([bounded], map_assignment)?
                .collect::<rusqlite::Result<Vec<_>>>()?,
        );
        assignments
            .into_iter()
            .map(|assignment| {
                let agent = query_agent(&connection, &assignment.agent_id)?.ok_or_else(|| {
                    EventStoreError::Internal("assignment agent disappeared".to_owned())
                })?;
                let latest_attempt = query_latest_attempt(&connection, &assignment.assignment_id)?;
                Ok(AssignmentExecutionCandidate {
                    agent,
                    assignment,
                    latest_attempt,
                })
            })
            .collect()
    }

    /// Claim one exact queued FIFO head and open its attempt atomically.
    ///
    /// The expected assignment id closes the scan/claim race: a stale
    /// dispatcher can never accidentally move some other FIFO head to Running
    /// and then abandon it because its process-local candidate differed.
    pub(crate) fn claim_exact_core_assignment(
        &self,
        assignment_id: &str,
        run_id: &str,
        baseline_event_sequence: u64,
    ) -> Result<Option<ClaimedAssignment>> {
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let Some(assignment) = query_assignment(&transaction, assignment_id)? else {
                transaction.commit()?;
                return Ok(None);
            };
            if assignment.status != AssignmentStatus::Queued {
                transaction.commit()?;
                return Ok(None);
            }
            let agent_open = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM agents
                 WHERE agent_id=?1 AND lifecycle='open')",
                [&assignment.agent_id],
                |row| row.get::<_, bool>(0),
            )?;
            let active = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM agent_assignments
                 WHERE agent_id=?1 AND status IN ('running','waiting'))",
                [&assignment.agent_id],
                |row| row.get::<_, bool>(0),
            )?;
            let earlier = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM agent_assignments
                 WHERE agent_id=?1 AND status='queued' AND queue_ordinal<?2)",
                params![assignment.agent_id, assignment.queue_ordinal],
                |row| row.get::<_, bool>(0),
            )?;
            if !agent_open || active || earlier {
                transaction.commit()?;
                return Ok(None);
            }
            let now = chrono::Utc::now().to_rfc3339();
            let changed = transaction.execute(
                "UPDATE agent_assignments
                 SET status='running',started_at=COALESCE(started_at,?2),updated_at=?2
                 WHERE assignment_id=?1 AND status='queued'",
                params![assignment_id, now],
            )?;
            if changed != 1 {
                transaction.commit()?;
                return Ok(None);
            }
            let attempt_number = transaction.query_row(
                "SELECT COALESCE(MAX(attempt_number),0)+1
                 FROM agent_assignment_attempts WHERE assignment_id=?1",
                [assignment_id],
                |row| row.get::<_, u32>(0),
            )?;
            let attempt_id = stable_attempt_id(assignment_id, attempt_number);
            transaction.execute(
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
            )?;
            let claimed = ClaimedAssignment {
                assignment: query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                    EventStoreError::Internal("claimed core assignment disappeared".to_owned())
                })?,
                attempt: query_attempt(&transaction, &attempt_id)?.ok_or_else(|| {
                    EventStoreError::Internal("claimed core attempt disappeared".to_owned())
                })?,
            };
            transaction.commit()?;
            Ok(Some(claimed))
        })
    }

    /// Open a new attempt for an already-running or unparked assignment.
    /// Fresh queued work continues to use the atomic FIFO claim operation.
    pub(crate) fn begin_core_assignment_resume(
        &self,
        assignment_id: &str,
        run_id: &str,
        baseline_event_sequence: u64,
    ) -> Result<Option<ClaimedAssignment>> {
        self.with_global_write_lock(|| {
            let mut connection = self.conn()?;
            let transaction =
                connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let mut assignment =
                query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                    EventStoreError::InvalidOperation(format!(
                        "agent assignment '{assignment_id}' was not found"
                    ))
                })?;
            if assignment.status == AssignmentStatus::Waiting {
                let pending_wait = transaction.query_row(
                    "SELECT EXISTS(
                       SELECT 1 FROM coordination_waits
                       WHERE owner_assignment_id=?1 AND disposition='pending'
                     )",
                    [assignment_id],
                    |row| row.get::<_, bool>(0),
                )?;
                if pending_wait {
                    transaction.commit()?;
                    return Ok(None);
                }
                let now = chrono::Utc::now().to_rfc3339();
                transaction.execute(
                    "UPDATE agent_assignments SET status='running',updated_at=?2
                     WHERE assignment_id=?1 AND status='waiting'",
                    params![assignment_id, now],
                )?;
                assignment = query_assignment(&transaction, assignment_id)?.ok_or_else(|| {
                    EventStoreError::Internal("unparked assignment disappeared".to_owned())
                })?;
            }
            if assignment.status != AssignmentStatus::Running {
                transaction.commit()?;
                return Ok(None);
            }
            let attempt_open = transaction.query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM agent_assignment_attempts
                   WHERE assignment_id=?1 AND completed_at IS NULL
                 )",
                [assignment_id],
                |row| row.get::<_, bool>(0),
            )?;
            if attempt_open {
                transaction.commit()?;
                return Ok(None);
            }
            let attempt_number = transaction.query_row(
                "SELECT COALESCE(MAX(attempt_number),0)+1
                 FROM agent_assignment_attempts WHERE assignment_id=?1",
                [assignment_id],
                |row| row.get::<_, u32>(0),
            )?;
            let attempt_id = stable_attempt_id(assignment_id, attempt_number);
            let now = chrono::Utc::now().to_rfc3339();
            transaction.execute(
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
            )?;
            let attempt = query_attempt(&transaction, &attempt_id)?.ok_or_else(|| {
                EventStoreError::Internal("resumed assignment attempt disappeared".to_owned())
            })?;
            transaction.commit()?;
            Ok(Some(ClaimedAssignment {
                assignment,
                attempt,
            }))
        })
    }

    /// Close one provider-run attempt without terminalizing its assignment.
    /// Parking and process interruption are evidence; later recovery opens a
    /// new attempt against the same transcript.
    pub(crate) fn finish_core_assignment_attempt(
        &self,
        attempt_id: &str,
        status: &str,
        error: Option<&str>,
    ) -> Result<bool> {
        if !matches!(status, "completed" | "failed" | "interrupted") {
            return Err(EventStoreError::InvalidOperation(
                "attempt terminal status must be completed, failed, or interrupted".to_owned(),
            ));
        }
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            let now = chrono::Utc::now().to_rfc3339();
            connection
                .execute(
                    "UPDATE agent_assignment_attempts
                     SET status=?2,completed_at=?3,error=?4
                     WHERE attempt_id=?1 AND completed_at IS NULL",
                    params![attempt_id, status, now, error],
                )
                .map(|changed| changed == 1)
                .map_err(EventStoreError::from)
        })
    }

    /// Repair all process-local custody after restart. Assignment state is
    /// intentionally retained: transcript evidence is reconciled before any
    /// resumed provider call, and wake causes remain exactly addressable.
    pub(crate) fn recover_core_agent_execution(&self) -> Result<AgentExecutionRecovery> {
        self.with_global_write_lock(|| {
            let connection = self.conn()?;
            let now = chrono::Utc::now().to_rfc3339();
            let interrupted_attempts = connection.execute(
                "UPDATE agent_assignment_attempts
                 SET status='interrupted',completed_at=?1,
                     error=COALESCE(error,'engine restarted during agent attempt')
                 WHERE completed_at IS NULL",
                [&now],
            )?;
            let recovered_wake_leases = connection.execute(
                "UPDATE agent_wake_intents
                 SET disposition='pending',lease_id=NULL,leased_at=NULL,
                     last_error=COALESCE(
                       last_error,'engine restarted before safe-boundary delivery'
                     )
                 WHERE disposition='leased'",
                [],
            )?;
            Ok(AgentExecutionRecovery {
                interrupted_attempts,
                recovered_wake_leases,
            })
        })
    }
}

fn query_agent(connection: &rusqlite::Connection, agent_id: &str) -> Result<Option<AgentRecord>> {
    connection
        .query_row(
            &format!("SELECT {AGENT_COLUMNS} FROM agents WHERE agent_id=?1"),
            [agent_id],
            map_agent,
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn query_assignment(
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

fn query_latest_attempt(
    connection: &rusqlite::Connection,
    assignment_id: &str,
) -> Result<Option<AssignmentAttemptRecord>> {
    connection
        .query_row(
            &format!(
                "SELECT {ATTEMPT_COLUMNS} FROM agent_assignment_attempts
                 WHERE assignment_id=?1 ORDER BY attempt_number DESC LIMIT 1"
            ),
            [assignment_id],
            map_attempt,
        )
        .optional()
        .map_err(EventStoreError::from)
}

fn query_attempt(
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

fn query_wake(
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

fn map_agent(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentRecord> {
    let visibility = AgentVisibility::parse(&row.get::<_, String>(7)?).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            7,
            rusqlite::types::Type::Text,
            "invalid agent visibility".into(),
        )
    })?;
    let lifecycle = AgentLifecycle::parse(&row.get::<_, String>(8)?).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            8,
            rusqlite::types::Type::Text,
            "invalid agent lifecycle".into(),
        )
    })?;
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
            capability_grant: parse_json(row, 11)?,
            write_scopes: parse_json(row, 12)?,
            limits: parse_json(row, 13)?,
        },
        created_at: row.get(14)?,
        updated_at: row.get(15)?,
        closed_at: row.get(16)?,
    })
}

fn map_assignment(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssignmentRecord> {
    let kind = AssignmentKind::parse(&row.get::<_, String>(6)?).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            6,
            rusqlite::types::Type::Text,
            "invalid assignment kind".into(),
        )
    })?;
    let status = AssignmentStatus::parse(&row.get::<_, String>(7)?).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            7,
            rusqlite::types::Type::Text,
            "invalid assignment status".into(),
        )
    })?;
    Ok(AssignmentRecord {
        assignment_id: row.get(0)?,
        admission_key: row.get(1)?,
        agent_id: row.get(2)?,
        requested_by_agent_id: row.get(3)?,
        parent_assignment_id: row.get(4)?,
        retry_of_assignment_id: row.get(5)?,
        kind,
        status,
        queue_ordinal: row.get(8)?,
        trace_id: row.get(9)?,
        autonomous_hop: row.get(10)?,
        causal_depth: row.get(11)?,
        causal_ordinal: row.get(12)?,
        task: row.get(13)?,
        context: parse_json(row, 14)?,
        model: row.get(15)?,
        reasoning_level: row.get(16)?,
        capability_snapshot: parse_json(row, 17)?,
        write_scopes_snapshot: parse_json(row, 18)?,
        limits_snapshot: parse_json(row, 19)?,
        deadline_at: row.get(20)?,
        created_at: row.get(21)?,
        accepted_at: row.get(22)?,
        started_at: row.get(23)?,
        completed_at: row.get(24)?,
        updated_at: row.get(25)?,
    })
}

fn map_attempt(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssignmentAttemptRecord> {
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

fn map_wake(row: &rusqlite::Row<'_>) -> rusqlite::Result<WakeIntentRecord> {
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

fn parse_json<T: serde::de::DeserializeOwned>(
    row: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<T> {
    let raw = row.get::<_, String>(index)?;
    serde_json::from_str(&raw).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

fn stable_attempt_id(assignment_id: &str, attempt_number: u32) -> String {
    use sha2::{Digest, Sha256};
    let mut digest = Sha256::new();
    digest.update(b"agent_attempt\0");
    digest.update(assignment_id.as_bytes());
    digest.update(b"\0");
    digest.update(attempt_number.to_string().as_bytes());
    format!("agent_attempt_{}", hex::encode(&digest.finalize()[..16]))
}

fn qualified_assignment_columns(alias: &str) -> String {
    ASSIGNMENT_COLUMNS
        .split(',')
        .map(str::trim)
        .filter(|column| !column.is_empty())
        .map(|column| format!("{alias}.{column}"))
        .collect::<Vec<_>>()
        .join(",")
}

//! Runnable, recoverable, due, FIFO-head, and provisioning scheduling state.
//!
//! Fresh admission and recovery remain independent bounded lanes.

use super::*;

impl WorkerStore {
    /// Return FIFO heads that the coordination supervisor may start.
    ///
    /// Active recovery is intentionally a separate query. Otherwise a large
    /// prefix of old running/waiting rows can consume this bounded page and
    /// permanently hide newly queued work for unrelated agents. Only one
    /// accepted/queued head per currently inactive agent is returned, so the
    /// runtime never spends its dispatch batch repeatedly rejecting later
    /// entries from one agent's queue.
    #[cfg(test)]
    pub(crate) fn list_runnable_agent_assignments(
        &self,
        limit: usize,
    ) -> Result<Vec<AgentAssignmentRecord>, String> {
        self.list_runnable_agent_assignments_page(limit, 0)
    }

    pub(crate) fn list_runnable_agent_assignments_page(
        &self,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<AgentAssignmentRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                 WHERE status IN ('accepted','queued')
                   AND EXISTS(
                    SELECT 1 FROM agent_instances agent
                    WHERE agent.agent_id=agent_assignments.agent_id
                      AND agent.state!='provisioning'
                   )
                   AND NOT EXISTS(
                    SELECT 1 FROM agent_assignments active
                    WHERE active.agent_id=agent_assignments.agent_id
                      AND active.status IN ('running','waiting')
                   )
                   AND NOT EXISTS(
                    SELECT 1 FROM agent_assignments earlier
                    WHERE earlier.agent_id=agent_assignments.agent_id
                      AND earlier.status IN ('accepted','queued')
                      AND (
                        earlier.queue_ordinal<agent_assignments.queue_ordinal
                        OR (
                          earlier.queue_ordinal=agent_assignments.queue_ordinal
                          AND earlier.assignment_id<agent_assignments.assignment_id
                        )
                      )
                   )
                   AND NOT EXISTS(
                    SELECT 1
                    FROM execution_nodes node
                    JOIN coordination_trace_states trace_state
                      ON trace_state.trace_id=node.trace_id AND trace_state.state='paused'
                    WHERE node.execution_id=agent_assignments.execution_id
                   )
                 ORDER BY created_at,assignment_id LIMIT ?1 OFFSET ?2"
            ))
            .map_err(|error| format!("prepare runnable agent assignments: {error}"))?;
        statement
            .query_map(
                params![
                    i64::try_from(limit.clamp(1, 256)).unwrap_or(256),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_assignment,
            )
            .map_err(|error| format!("query runnable agent assignments: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode runnable agent assignments: {error}"))
    }

    /// Return assignments whose already-started supervision must be recovered
    /// or whose parked joins must be reconciled. This lane has its own bounded
    /// page so it can neither hide nor be hidden by fresh FIFO work.
    #[cfg(test)]
    pub(crate) fn list_recoverable_agent_assignments(
        &self,
        limit: usize,
    ) -> Result<Vec<AgentAssignmentRecord>, String> {
        self.list_recoverable_agent_assignments_page(limit, 0)
    }

    pub(crate) fn list_recoverable_agent_assignments_page(
        &self,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<AgentAssignmentRecord>, String> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                 WHERE status IN ('running','waiting')
                   AND EXISTS(
                    SELECT 1 FROM agent_instances agent
                    WHERE agent.agent_id=agent_assignments.agent_id
                      AND agent.state!='provisioning'
                   )
                   AND NOT EXISTS(
                    SELECT 1
                    FROM execution_nodes node
                    JOIN coordination_trace_states trace_state
                      ON trace_state.trace_id=node.trace_id AND trace_state.state='paused'
                    WHERE node.execution_id=agent_assignments.execution_id
                   )
                 ORDER BY CASE status WHEN 'running' THEN 0 ELSE 1 END,
                          created_at,assignment_id LIMIT ?1 OFFSET ?2"
            ))
            .map_err(|error| format!("prepare recoverable agent assignments: {error}"))?;
        statement
            .query_map(
                params![
                    i64::try_from(limit.clamp(1, 256)).unwrap_or(256),
                    i64::try_from(offset).unwrap_or(i64::MAX),
                ],
                map_assignment,
            )
            .map_err(|error| format!("query recoverable agent assignments: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode recoverable agent assignments: {error}"))
    }

    /// Return every nonterminal assignment whose immutable admission deadline
    /// is due. Paused traces are intentionally included: autonomy pause stops
    /// execution, not wall-clock budget enforcement or cleanup.
    pub(crate) fn list_due_agent_assignments(
        &self,
        now: &str,
        limit: usize,
    ) -> Result<Vec<AgentAssignmentRecord>, String> {
        chrono::DateTime::parse_from_rfc3339(now)
            .map_err(|_| "agent due-assignment cutoff must be an RFC 3339 timestamp".to_owned())?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(&format!(
                "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                 WHERE status IN ('offered','accepted','queued','running','waiting')
                   AND deadline_at IS NOT NULL
                   AND julianday(deadline_at)<=julianday(?1)
                 ORDER BY julianday(deadline_at),created_at,assignment_id LIMIT ?2"
            ))
            .map_err(|error| format!("prepare due agent assignments: {error}"))?;
        statement
            .query_map(
                params![now, i64::try_from(limit.clamp(1, 256)).unwrap_or(256)],
                map_assignment,
            )
            .map_err(|error| format!("query due agent assignments: {error}"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| format!("decode due agent assignments: {error}"))
    }

    /// Return the oldest accepted/queued assignment for one reusable agent.
    /// The unique active-assignment index prevents this from racing a second
    /// running assignment once the caller performs the state CAS.
    pub(crate) fn next_queued_agent_assignment(
        &self,
        agent_id: &str,
    ) -> Result<Option<AgentAssignmentRecord>, String> {
        validate_runtime_identifier(agent_id, "agent id", 256)?;
        let connection = self.connection()?;
        connection
            .query_row(
                &format!(
                    "SELECT {ASSIGNMENT_COLUMNS} FROM agent_assignments
                     WHERE agent_id=?1 AND status IN ('accepted','queued')
                       AND NOT EXISTS(
                        SELECT 1
                        FROM execution_nodes node
                        JOIN coordination_trace_states trace_state
                          ON trace_state.trace_id=node.trace_id AND trace_state.state='paused'
                        WHERE node.execution_id=agent_assignments.execution_id
                       )
                     ORDER BY queue_ordinal,created_at,assignment_id LIMIT 1"
                ),
                [agent_id],
                map_assignment,
            )
            .optional()
            .map_err(|error| format!("load next reusable agent assignment: {error}"))
    }

    /// Complete the cross-store provisioning handshake without manufacturing
    /// a replacement identity. This transition is deliberately idempotent so
    /// an EventStore import acknowledged after a crash can be replayed.
    pub(crate) fn mark_agent_provisioned(
        &self,
        agent_id: &str,
        assignment_id: &str,
    ) -> Result<AgentAssignmentRecord, String> {
        validate_runtime_identifier(agent_id, "agent id", 256)?;
        validate_runtime_identifier(assignment_id, "assignment id", 256)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| format!("start agent provisioning acknowledgement: {error}"))?;
        let agent = require_agent(&transaction, agent_id, "provisioned agent")?;
        let assignment = query_assignment(&transaction, assignment_id)?
            .ok_or_else(|| format!("agent assignment '{assignment_id}' was not found"))?;
        if assignment.agent_id != agent_id {
            return Err("provisioning assignment does not belong to the agent".to_owned());
        }
        // A crash can occur after this handshake but after the supervisor has
        // already advanced queued work. Any state beyond the exact initial
        // provisioning/accepted pair therefore proves the durable handshake
        // ran and is a valid acknowledgement replay.
        let replay = agent.state != AgentInstanceState::Provisioning
            && assignment.status != AgentAssignmentStatus::Accepted;
        if !replay {
            if agent.state != AgentInstanceState::Provisioning
                || assignment.status != AgentAssignmentStatus::Accepted
            {
                return Err(format!(
                    "agent provisioning acknowledgement requires provisioning/accepted, found {}/{}",
                    agent.state.as_str(),
                    assignment.status.as_str()
                ));
            }
            let now = chrono::Utc::now().to_rfc3339();
            transaction
                .execute(
                    "UPDATE agent_instances SET state='active',updated_at=?2
                     WHERE agent_id=?1 AND state='provisioning'",
                    params![agent_id, now],
                )
                .map_err(|error| format!("activate provisioned agent: {error}"))?;
            transaction
                .execute(
                    "UPDATE agent_assignments
                     SET status='queued',updated_at=?3
                     WHERE assignment_id=?1 AND agent_id=?2 AND status='accepted'",
                    params![assignment_id, agent_id, now],
                )
                .map_err(|error| format!("queue provisioned agent assignment: {error}"))?;
            append_execution_event_in_tx(
                &transaction,
                &assignment.execution_id,
                "provisioned",
                &json!({"agentId":agent_id,"assignmentStatus":"queued"}),
                &now,
            )?;
        }
        let record = query_assignment(&transaction, assignment_id)?
            .ok_or_else(|| "provisioned assignment disappeared".to_owned())?;
        transaction
            .commit()
            .map_err(|error| format!("commit agent provisioning acknowledgement: {error}"))?;
        Ok(record)
    }
}
